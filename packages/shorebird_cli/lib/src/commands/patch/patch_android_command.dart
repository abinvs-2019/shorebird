import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped/scoped.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_analysis.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/command.dart';
import 'package:shorebird_cli/src/config/shorebird_yaml.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/formatters/formatters.dart';
import 'package:shorebird_cli/src/logger.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/shorebird_build_mixin.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/shorebird_release_version_mixin.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template patch_android_command}
/// `shorebird patch android`
/// Publish new patches for a specific Android release to the Shorebird code
/// push server.
/// {@endtemplate}
class PatchAndroidCommand extends ShorebirdCommand
    with ShorebirdBuildMixin, ShorebirdReleaseVersionMixin {
  /// {@macro patch_android_command}
  PatchAndroidCommand({
    HashFunction? hashFn,
    http.Client? httpClient,
    AndroidArchiveDiffer? archiveDiffer,
  })  : _archiveDiffer = archiveDiffer ?? AndroidArchiveDiffer(),
        _hashFn = hashFn ?? ((m) => sha256.convert(m).toString()),
        _httpClient = httpClient ?? http.Client() {
    argParser
      ..addOption(
        'release-version',
        help: 'The version of the release (e.g. "1.0.0").',
      )
      ..addOption(
        'target',
        abbr: 't',
        help: 'The main entrypoint file of the application.',
      )
      ..addOption(
        'flavor',
        help: 'The product flavor to use when building the app.',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Patch without confirmation if there are no errors.',
        negatable: false,
      )
      ..addFlag(
        'dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Validate but do not upload the patch.',
      );
  }

  @override
  String get description =>
      'Publish new patches for a specific Android release to Shorebird.';

  @override
  String get name => 'android';

  final ArchiveDiffer _archiveDiffer;
  final HashFunction _hashFn;
  final http.Client _httpClient;

  @override
  Future<int> run() async {
    try {
      await shorebirdValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
        checkShorebirdInitialized: true,
        validators: doctor.androidCommandValidators,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    final force = results['force'] == true;
    final dryRun = results['dry-run'] == true;

    if (force && dryRun) {
      logger.err('Cannot use both --force and --dry-run.');
      return ExitCode.usage.code;
    }

    await cache.updateAll();

    const platform = ReleasePlatform.android;
    const channelName = 'stable';
    final flavor = results['flavor'] as String?;
    final target = results['target'] as String?;
    final shorebirdYaml = shorebirdEnv.getShorebirdYaml()!;
    final appId = shorebirdYaml.getAppId(flavor: flavor);
    final app = await codePushClientWrapper.getApp(appId: appId);
    final releases = await codePushClientWrapper.getReleases(appId: appId);

    if (releases.isEmpty) {
      logger.info('No releases found');
      return ExitCode.success.code;
    }

    final releaseVersion = results['release-version'] as String? ??
        await promptForReleaseVersion(releases);

    final release = releases.firstWhereOrNull(
      (r) => r.version == releaseVersion,
    );

    if (releaseVersion == null || release == null) {
      logger.info('''
No release found for version $releaseVersion

Available release versions:
${releases.map((r) => r.version).join('\n')}''');
      return ExitCode.success.code;
    }

    if (release.platformStatuses[ReleasePlatform.android] ==
        ReleaseStatus.draft) {
      logger.err('''
Release $releaseVersion is in an incomplete state. It's possible that the original release was terminated or failed to complete.
Please re-run the release command for this version or create a new release.''');
      return ExitCode.software.code;
    }

    final releaseArtifacts = await codePushClientWrapper.getReleaseArtifacts(
      appId: app.appId,
      releaseId: release.id,
      architectures: architectures,
      platform: platform,
    );

    final releaseAabArtifact = await codePushClientWrapper.getReleaseArtifact(
      appId: app.appId,
      releaseId: release.id,
      arch: 'aab',
      platform: platform,
    );

    final releaseArtifactPaths = <Arch, String>{};
    final downloadReleaseArtifactProgress = logger.progress(
      'Downloading release artifacts',
    );
    for (final releaseArtifact in releaseArtifacts.entries) {
      try {
        final releaseArtifactPath = await downloadReleaseArtifact(
          Uri.parse(releaseArtifact.value.url),
          httpClient: _httpClient,
        );
        releaseArtifactPaths[releaseArtifact.key] = releaseArtifactPath;
      } catch (error) {
        downloadReleaseArtifactProgress.fail('$error');
        return ExitCode.software.code;
      }
    }

    downloadReleaseArtifactProgress.complete();

    final shorebirdFlutterRevision = shorebirdEnv.flutterRevision;
    if (release.flutterRevision != shorebirdFlutterRevision) {
      final installFlutterRevisionProgress = logger.progress(
        'Switching to Flutter revision ${release.flutterRevision}',
      );
      try {
        await shorebirdFlutter.installRevision(
          revision: release.flutterRevision,
        );
        installFlutterRevisionProgress.complete();
      } catch (error) {
        installFlutterRevisionProgress.fail('$error');
        return ExitCode.software.code;
      }
    }

    final buildProgress = logger.progress('Building patch');
    try {
      await runScoped(
        () => buildAppBundle(flavor: flavor, target: target),
        values: {
          shorebirdEnvRef.overrideWith(
            () => ShorebirdEnv(
              flutterRevisionOverride: release.flutterRevision,
            ),
          )
        },
      );
      buildProgress.complete();
    } on ProcessException catch (error) {
      buildProgress.fail('Failed to build: ${error.message}');
      return ExitCode.software.code;
    }

    final bundlePath = flavor != null
        ? './build/app/outputs/bundle/${flavor}Release/app-$flavor-release.aab'
        : './build/app/outputs/bundle/release/app-release.aab';

    final detectReleaseVersionProgress = logger.progress(
      'Detecting release version',
    );
    final String localReleaseVersion;
    try {
      localReleaseVersion = await extractReleaseVersionFromAppBundle(
        bundlePath,
      );
      detectReleaseVersionProgress.complete(
        'Detected release version $localReleaseVersion',
      );
    } catch (error) {
      detectReleaseVersionProgress.fail('$error');
      return ExitCode.software.code;
    }

    if (localReleaseVersion != releaseVersion) {
      logger.err('''
The local release version ($localReleaseVersion) does not match the remote release version ($releaseVersion).
Please re-run the release command for this version or create a new release.''');
      return ExitCode.software.code;
    }

    final shouldContinue =
        await patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
      localArtifact: File(bundlePath),
      releaseArtifactUrl: Uri.parse(releaseAabArtifact.url),
      archiveDiffer: _archiveDiffer,
      force: force,
    );

    if (!shouldContinue) return ExitCode.success.code;

    final patchArtifactBundles = <Arch, PatchArtifactBundle>{};
    final createDiffProgress = logger.progress('Creating artifacts');

    for (final releaseArtifactPath in releaseArtifactPaths.entries) {
      final archMetadata = architectures[releaseArtifactPath.key]!;
      final patchArtifactPath = p.join(
        Directory.current.path,
        'build',
        'app',
        'intermediates',
        'stripped_native_libs',
        flavor != null ? '${flavor}Release' : 'release',
        'out',
        'lib',
        archMetadata.path,
        'libapp.so',
      );
      logger.detail('Creating artifact for $patchArtifactPath');
      final patchArtifact = File(patchArtifactPath);
      final hash = _hashFn(await patchArtifact.readAsBytes());
      try {
        final diffPath = await createDiff(
          releaseArtifactPath: releaseArtifactPath.value,
          patchArtifactPath: patchArtifactPath,
        );
        patchArtifactBundles[releaseArtifactPath.key] = PatchArtifactBundle(
          arch: archMetadata.arch,
          path: diffPath,
          hash: hash,
          size: await File(diffPath).length(),
        );
      } catch (error) {
        createDiffProgress.fail('$error');
        return ExitCode.software.code;
      }
    }
    createDiffProgress.complete();

    final archMetadata = patchArtifactBundles.keys.map((arch) {
      final name = arch.name;
      final size = formatBytes(patchArtifactBundles[arch]!.size);
      return '$name ($size)';
    });

    if (dryRun) {
      logger
        ..info('No issues detected.')
        ..info('The server may enforce additional checks.');
      return ExitCode.success.code;
    }

    final summary = [
      '''📱 App: ${lightCyan.wrap(app.displayName)} ${lightCyan.wrap('(${app.appId})')}''',
      if (flavor != null) '🍧 Flavor: ${lightCyan.wrap(flavor)}',
      '📦 Release Version: ${lightCyan.wrap(releaseVersion)}',
      '📺 Channel: ${lightCyan.wrap(channelName)}',
      '''🕹️  Platform: ${lightCyan.wrap(platform.name)} ${lightCyan.wrap('[${archMetadata.join(', ')}]')}''',
    ];

    logger.info(
      '''

${styleBold.wrap(lightGreen.wrap('🚀 Ready to publish a new patch!'))}

${summary.join('\n')}
''',
    );

    final needsConfirmation = !force && !shorebirdEnv.isRunningOnCI;
    if (needsConfirmation) {
      final confirm = logger.confirm('Would you like to continue?');

      if (!confirm) {
        logger.info('Aborting.');
        return ExitCode.success.code;
      }
    }

    await codePushClientWrapper.publishPatch(
      appId: appId,
      releaseId: release.id,
      platform: platform,
      channelName: channelName,
      patchArtifactBundles: patchArtifactBundles,
    );

    logger.success('\n✅ Published Patch!');
    return ExitCode.success.code;
  }

  Future<String?> promptForReleaseVersion(List<Release> releases) async {
    if (releases.isEmpty) return null;
    final release = logger.chooseOne(
      'Which release would you like to patch?',
      choices: releases,
      display: (release) => release.version,
    );
    return release.version;
  }

  Future<String> downloadReleaseArtifact(
    Uri uri, {
    required http.Client httpClient,
  }) async {
    final request = http.Request('GET', uri);
    final response = await httpClient.send(request);

    if (response.statusCode != HttpStatus.ok) {
      throw Exception(
        '''Failed to download release artifact: ${response.statusCode} ${response.reasonPhrase}''',
      );
    }

    final tempDir = await Directory.systemTemp.createTemp();
    final releaseArtifact = File(p.join(tempDir.path, 'artifact.so'));
    await releaseArtifact.openWrite().addStream(response.stream);

    return releaseArtifact.path;
  }
}
