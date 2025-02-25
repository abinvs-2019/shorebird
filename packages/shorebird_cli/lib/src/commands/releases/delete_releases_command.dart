import 'dart:async';

import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/command.dart';
import 'package:shorebird_cli/src/config/shorebird_yaml.dart';
import 'package:shorebird_cli/src/logger.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template delete_releases_command}
///
/// `shorebird releases delete`
/// Delete the specified release.
/// {@endtemplate}
class DeleteReleasesCommand extends ShorebirdCommand {
  /// {@macro delete_releases_command}
  DeleteReleasesCommand() {
    argParser
      ..addOption(
        'version',
        help: 'The release version to delete.',
      )
      ..addOption(
        'flavor',
        help: 'The product flavor to use when deleting releases.',
      );
  }

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete the specified release version.';

  @override
  Future<int> run() async {
    try {
      await shorebirdValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
        checkShorebirdInitialized: true,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    final flavor = results['flavor'] as String?;
    final appId = shorebirdEnv.getShorebirdYaml()!.getAppId(flavor: flavor);

    final List<Release> releases;
    var progress = logger.progress('Fetching releases');
    try {
      releases = await codePushClientWrapper.codePushClient.getReleases(
        appId: appId,
      );
      progress.complete('Fetched releases.');
    } catch (error) {
      progress.fail('$error');
      return ExitCode.software.code;
    }

    final versionInput = results['version'] as String? ??
        logger.prompt(
          '${lightGreen.wrap('?')} Which version would you like to delete?',
        );

    final releaseToDelete = releases.firstWhereOrNull(
      (release) => release.version == versionInput,
    );
    if (releaseToDelete == null) {
      logger.err('No release found for version "$versionInput"');
      return ExitCode.software.code;
    }

    final shouldDelete = logger.confirm(
      'Are you sure you want to delete release ${releaseToDelete.version}?',
    );
    if (!shouldDelete) {
      logger.info('Aborted.');
      return ExitCode.success.code;
    }

    progress = logger.progress('Deleting release');

    try {
      await codePushClientWrapper.codePushClient.deleteRelease(
        appId: appId,
        releaseId: releaseToDelete.id,
      );
    } catch (error) {
      progress.fail('$error');
      return ExitCode.software.code;
    }

    progress.complete('Deleted release ${releaseToDelete.version}.');

    return ExitCode.success.code;
  }
}
