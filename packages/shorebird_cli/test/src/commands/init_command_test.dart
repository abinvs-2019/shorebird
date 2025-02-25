import 'dart:io' hide Platform;

import 'package:args/args.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:scoped/scoped.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/init_command.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/gradlew.dart';
import 'package:shorebird_cli/src/logger.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/process.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/xcodebuild.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

class _MockArgResults extends Mock implements ArgResults {}

class _MockCodePushClientWrapper extends Mock
    implements CodePushClientWrapper {}

class _MockDoctor extends Mock implements Doctor {}

class _MockGradlew extends Mock implements Gradlew {}

class _MockFile extends Mock implements File {}

class _MockLogger extends Mock implements Logger {}

class _MockPlatform extends Mock implements Platform {}

class _MockProgress extends Mock implements Progress {}

class _MockShorebirdEnv extends Mock implements ShorebirdEnv {}

class _MockShorebirdValidator extends Mock implements ShorebirdValidator {}

class _MockXcodeBuild extends Mock implements XcodeBuild {}

void main() {
  group(InitCommand, () {
    const version = '1.2.3';
    const appId = 'test_app_id';
    const appName = 'test_app_name';
    const app = App(id: appId, displayName: appName);
    const pubspecYamlContent = '''
name: $appName
version: $version
environment:
  sdk: ">=2.19.0 <3.0.0"''';

    late ArgResults argResults;
    late Doctor doctor;
    late Gradlew gradlew;
    late CodePushClientWrapper codePushClientWrapper;
    late File shorebirdYamlFile;
    late File pubspecYamlFile;
    late Logger logger;
    late Platform platform;
    late Progress progress;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdValidator shorebirdValidator;
    late XcodeBuild xcodeBuild;
    late InitCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
          doctorRef.overrideWith(() => doctor),
          gradlewRef.overrideWith(() => gradlew),
          loggerRef.overrideWith(() => logger),
          platformRef.overrideWith(() => platform),
          processRef.overrideWith(() => process),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          shorebirdValidatorRef.overrideWith(() => shorebirdValidator),
          xcodeBuildRef.overrideWith(() => xcodeBuild),
        },
      );
    }

    setUp(() {
      argResults = _MockArgResults();
      doctor = _MockDoctor();
      gradlew = _MockGradlew();
      codePushClientWrapper = _MockCodePushClientWrapper();
      shorebirdYamlFile = _MockFile();
      pubspecYamlFile = _MockFile();
      logger = _MockLogger();
      platform = _MockPlatform();
      progress = _MockProgress();
      shorebirdEnv = _MockShorebirdEnv();
      shorebirdValidator = _MockShorebirdValidator();
      xcodeBuild = _MockXcodeBuild();

      when(
        () => codePushClientWrapper.createApp(appName: any(named: 'appName')),
      ).thenAnswer((_) async => app);
      when(
        () => doctor.runValidators(any(), applyFixes: any(named: 'applyFixes')),
      ).thenAnswer((_) async => {});
      when(() => doctor.allValidators).thenReturn([]);
      when(
        () => shorebirdEnv.getShorebirdYamlFile(),
      ).thenReturn(shorebirdYamlFile);
      when(() => shorebirdEnv.getPubspecYamlFile()).thenReturn(pubspecYamlFile);
      when(
        () => pubspecYamlFile.readAsStringSync(),
      ).thenReturn(pubspecYamlContent);
      when(
        () => pubspecYamlFile.uri,
      ).thenReturn(File(p.join('pubspec.yaml')).uri);
      when(
        () => logger.prompt(any(), defaultValue: any(named: 'defaultValue')),
      ).thenReturn(appName);
      when(() => logger.progress(any())).thenReturn(progress);
      when(() => gradlew.productFlavors(any())).thenAnswer((_) async => {});
      when(() => platform.isMacOS).thenReturn(true);
      when(() => shorebirdEnv.hasPubspecYaml).thenReturn(true);
      when(() => shorebirdEnv.hasShorebirdYaml).thenReturn(false);
      when(() => shorebirdEnv.pubspecContainsShorebirdYaml).thenReturn(false);
      when(
        () => shorebirdValidator.validatePreconditions(
          checkUserIsAuthenticated: any(named: 'checkUserIsAuthenticated'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => xcodeBuild.list(any()),
      ).thenAnswer((_) async => const XcodeProjectBuildInfo());

      command = runWithOverrides(InitCommand.new)..testArgResults = argResults;
    });

    test('exits when validation fails', () async {
      final exception = ValidationFailedException();
      when(
        () => shorebirdValidator.validatePreconditions(
          checkUserIsAuthenticated: any(named: 'checkUserIsAuthenticated'),
        ),
      ).thenThrow(exception);
      await expectLater(
        runWithOverrides(command.run),
        completion(equals(exception.exitCode.code)),
      );
      verify(
        () => shorebirdValidator.validatePreconditions(
          checkUserIsAuthenticated: true,
        ),
      ).called(1);
    });

    test('throws no input error when pubspec.yaml is not found.', () async {
      when(() => shorebirdEnv.hasPubspecYaml).thenReturn(false);
      final exitCode = await runWithOverrides(command.run);
      verify(
        () => logger.err(
          '''
Could not find a "pubspec.yaml".
Please make sure you are running "shorebird init" from the root of your Flutter project.
''',
        ),
      ).called(1);
      expect(exitCode, ExitCode.noInput.code);
    });

    test('throws software error when pubspec.yaml is malformed.', () async {
      final exception = Exception('oops');
      when(() => shorebirdEnv.hasPubspecYaml).thenThrow(exception);
      final exitCode = await runWithOverrides(command.run);
      verify(
        () => logger.err('Error parsing "pubspec.yaml": $exception'),
      ).called(1);
      expect(exitCode, ExitCode.software.code);
    });

    test('throws software error when shorebird.yaml already exists', () async {
      when(() => shorebirdEnv.hasShorebirdYaml).thenReturn(true);
      final exitCode = await runWithOverrides(command.run);
      verify(
        () => logger.err(
          '''
A "shorebird.yaml" already exists.
If you want to reinitialize Shorebird, please run "shorebird init --force".''',
        ),
      ).called(1);
      expect(exitCode, ExitCode.software.code);
    });

    test('--force overwrites existing shorebird.yaml', () async {
      when(() => shorebirdEnv.hasShorebirdYaml).thenReturn(true);
      when(() => argResults['force']).thenReturn(true);
      final exitCode = await runWithOverrides(command.run);
      verifyNever(
        () => logger.err(
          '''
A "shorebird.yaml" already exists.
If you want to reinitialize Shorebird, please run "shorebird init --force".''',
        ),
      );
      expect(exitCode, ExitCode.success.code);
      verify(
        () => shorebirdYamlFile.writeAsStringSync(
          any(that: contains('app_id: $appId')),
        ),
      ).called(1);
    });

    test('fails when an error occurs while extracting flavors', () async {
      final exception = Exception('oops');
      when(() => gradlew.productFlavors(any())).thenThrow(exception);
      final exitCode = await runWithOverrides(command.run);
      verify(() => logger.progress('Detecting product flavors')).called(1);
      verify(
        () => logger.err(
          any(that: contains('Unable to extract product flavors.')),
        ),
      ).called(1);
      verify(() => progress.fail()).called(1);
      expect(exitCode, ExitCode.software.code);
    });

    test('throws software error when error occurs creating app.', () async {
      final error = Exception('oops');
      when(
        () => codePushClientWrapper.createApp(appName: any(named: 'appName')),
      ).thenThrow(error);
      final exitCode = await runWithOverrides(command.run);
      verify(
        () => logger.prompt(any(), defaultValue: any(named: 'defaultValue')),
      ).called(1);
      verify(() => logger.err('$error')).called(1);
      expect(exitCode, ExitCode.software.code);
    });

    group('on non MacOS', () {
      setUp(() {
        when(() => platform.isMacOS).thenReturn(false);
      });

      test('throws software error when unable to detect schemes', () async {
        final tempDir = Directory.systemTemp.createTempSync();
        Directory(p.join(tempDir.path, 'ios')).createSync(recursive: true);
        final exitCode = await IOOverrides.runZoned(
          () => runWithOverrides(command.run),
          getCurrentDirectory: () => tempDir,
        );
        expect(exitCode, equals(ExitCode.software.code));
        verify(
          () => logger.err(
            any(that: contains('Unable to detect iOS schemes in')),
          ),
        ).called(1);
        verifyNever(() => xcodeBuild.list(any()));
      });

      test('creates shorebird for an android-only app', () async {
        final tempDir = Directory.systemTemp.createTempSync();
        final exitCode = await IOOverrides.runZoned(
          () => runWithOverrides(command.run),
          getCurrentDirectory: () => tempDir,
        );
        expect(exitCode, equals(ExitCode.success.code));
        verify(
          () => shorebirdYamlFile.writeAsStringSync(
            any(that: contains('app_id: $appId')),
          ),
        ).called(1);
        verifyNever(() => xcodeBuild.list(any()));
      });

      test('creates shorebird for an app without flavors', () async {
        final tempDir = Directory.systemTemp.createTempSync();
        when(
          () => gradlew.productFlavors(any()),
        ).thenThrow(MissingAndroidProjectException(tempDir.path));
        File(
          p.join(
            tempDir.path,
            'ios',
            'Runner.xcodeproj',
            'xcshareddata',
            'xcschemes',
            'Runner.xcscheme',
          ),
        ).createSync(recursive: true);
        final exitCode = await IOOverrides.runZoned(
          () => runWithOverrides(command.run),
          getCurrentDirectory: () => tempDir,
        );
        expect(exitCode, equals(ExitCode.success.code));
        verify(
          () => shorebirdYamlFile.writeAsStringSync(
            any(that: contains('app_id: $appId')),
          ),
        ).called(1);
        verifyNever(() => xcodeBuild.list(any()));
      });

      test('creates shorebird for an app with flavors', () async {
        const appIds = ['test-appId-1', 'test-appId-2'];
        var index = 0;
        when(
          () => codePushClientWrapper.createApp(appName: any(named: 'appName')),
        ).thenAnswer((invocation) async {
          final appName = invocation.namedArguments[#appName] as String?;
          return App(id: appIds[index++], displayName: appName ?? '-');
        });
        final tempDir = Directory.systemTemp.createTempSync();
        when(
          () => gradlew.productFlavors(any()),
        ).thenThrow(MissingAndroidProjectException(tempDir.path));
        final schemesPath = p.join(
          tempDir.path,
          'ios',
          'Runner.xcodeproj',
          'xcshareddata',
          'xcschemes',
        );
        File(
          p.join(schemesPath, 'Runner.xcscheme'),
        ).createSync(recursive: true);
        File(
          p.join(schemesPath, 'internal.xcscheme'),
        ).createSync(recursive: true);
        File(
          p.join(schemesPath, 'stable.xcscheme'),
        ).createSync(recursive: true);
        final exitCode = await IOOverrides.runZoned(
          () => runWithOverrides(command.run),
          getCurrentDirectory: () => tempDir,
        );
        expect(exitCode, equals(ExitCode.success.code));
        verify(
          () => shorebirdYamlFile.writeAsStringSync(
            any(
              that: contains('''
app_id: ${appIds[0]}
flavors:
  internal: ${appIds[0]}
  stable: ${appIds[1]}'''),
            ),
          ),
        ).called(1);
        verifyInOrder([
          () => codePushClientWrapper.createApp(appName: '$appName (internal)'),
          () => codePushClientWrapper.createApp(appName: '$appName (stable)'),
        ]);
        verifyNever(() => xcodeBuild.list(any()));
      });
    });

    test('creates shorebird.yaml for an app without flavors', () async {
      await runWithOverrides(command.run);
      verify(
        () => shorebirdYamlFile.writeAsStringSync(
          any(that: contains('app_id: $appId')),
        ),
      );
    });

    group('creates shorebird.yaml for an app with flavors', () {
      test('android only', () async {
        final appIds = [
          'test-appId-1',
          'test-appId-2',
          'test-appId-3',
          'test-appId-4',
          'test-appId-5',
          'test-appId-6',
        ];
        var index = 0;
        when(() => gradlew.productFlavors(any())).thenAnswer(
          (_) async => {
            'development',
            'developmentInternal',
            'production',
            'productionInternal',
            'staging',
            'stagingInternal',
          },
        );
        when(
          () => codePushClientWrapper.createApp(appName: any(named: 'appName')),
        ).thenAnswer((invocation) async {
          final appName = invocation.namedArguments[#appName] as String?;
          return App(id: appIds[index++], displayName: appName ?? '--');
        });
        when(
          () => xcodeBuild.list(any()),
        ).thenThrow(const MissingIOSProjectException(''));
        await runWithOverrides(command.run);
        verify(
          () => shorebirdYamlFile.writeAsStringSync(
            any(
              that: contains('''
app_id: ${appIds[0]}
flavors:
  development: ${appIds[0]}
  developmentInternal: ${appIds[1]}
  production: ${appIds[2]}
  productionInternal: ${appIds[3]}
  staging: ${appIds[4]}
  stagingInternal: ${appIds[5]}'''),
            ),
          ),
        );
        verifyInOrder([
          () => codePushClientWrapper.createApp(
                appName: '$appName (development)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (developmentInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (production)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (productionInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (staging)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (stagingInternal)',
              ),
        ]);
      });

      test('ios only', () async {
        final appIds = [
          'test-appId-1',
          'test-appId-2',
          'test-appId-3',
          'test-appId-4',
          'test-appId-5',
          'test-appId-6'
        ];
        var index = 0;
        when(() => xcodeBuild.list(any())).thenAnswer(
          (_) async => const XcodeProjectBuildInfo(
            schemes: {
              'development',
              'developmentInternal',
              'production',
              'productionInternal',
              'staging',
              'stagingInternal',
            },
          ),
        );
        when(
          () => codePushClientWrapper.createApp(appName: any(named: 'appName')),
        ).thenAnswer((invocation) async {
          final appName = invocation.namedArguments[#appName] as String?;
          return App(id: appIds[index++], displayName: appName ?? '-');
        });
        when(
          () => gradlew.productFlavors(any()),
        ).thenThrow(const MissingAndroidProjectException(''));
        await runWithOverrides(command.run);
        verify(
          () => shorebirdYamlFile.writeAsStringSync(
            any(
              that: contains('''
app_id: ${appIds[0]}
flavors:
  development: ${appIds[0]}
  developmentInternal: ${appIds[1]}
  production: ${appIds[2]}
  productionInternal: ${appIds[3]}
  staging: ${appIds[4]}
  stagingInternal: ${appIds[5]}'''),
            ),
          ),
        );
        verifyInOrder([
          () => codePushClientWrapper.createApp(
                appName: '$appName (development)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (developmentInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (production)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (productionInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (staging)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (stagingInternal)',
              ),
        ]);
      });

      test('ios w/flavors and android w/out flavors', () async {
        final appIds = [
          'test-appId-1',
          'test-appId-2',
          'test-appId-3',
          'test-appId-4',
          'test-appId-5',
          'test-appId-6',
          'test-appId-7'
        ];
        var index = 0;
        when(() => xcodeBuild.list(any())).thenAnswer(
          (_) async => const XcodeProjectBuildInfo(
            schemes: {
              'development',
              'developmentInternal',
              'production',
              'productionInternal',
              'staging',
              'stagingInternal',
            },
          ),
        );
        when(() => gradlew.productFlavors(any())).thenAnswer((_) async => {});
        when(
          () => codePushClientWrapper.createApp(appName: any(named: 'appName')),
        ).thenAnswer((invocation) async {
          final appName = invocation.namedArguments[#appName] as String?;
          return App(id: appIds[index++], displayName: appName ?? '--');
        });
        await runWithOverrides(command.run);
        verify(
          () => shorebirdYamlFile.writeAsStringSync(
            any(
              that: contains('''
app_id: ${appIds[0]}
flavors:
  development: ${appIds[1]}
  developmentInternal: ${appIds[2]}
  production: ${appIds[3]}
  productionInternal: ${appIds[4]}
  staging: ${appIds[5]}
  stagingInternal: ${appIds[6]}'''),
            ),
          ),
        );
        verifyInOrder([
          () => codePushClientWrapper.createApp(
                appName: '$appName (development)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (developmentInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (production)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (productionInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (staging)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (stagingInternal)',
              ),
        ]);
      });

      test('android w/flavors and ios w/out flavors', () async {
        final appIds = [
          'test-appId-1',
          'test-appId-2',
          'test-appId-3',
          'test-appId-4',
          'test-appId-5',
          'test-appId-6',
          'test-appId-7'
        ];
        var index = 0;
        when(() => xcodeBuild.list(any())).thenAnswer(
          (_) async => const XcodeProjectBuildInfo(),
        );
        when(() => gradlew.productFlavors(any())).thenAnswer(
          (_) async => {
            'development',
            'developmentInternal',
            'production',
            'productionInternal',
            'staging',
            'stagingInternal',
          },
        );
        when(
          () => codePushClientWrapper.createApp(appName: any(named: 'appName')),
        ).thenAnswer((invocation) async {
          final appName = invocation.namedArguments[#appName] as String?;
          return App(id: appIds[index++], displayName: appName ?? '-');
        });
        await runWithOverrides(command.run);
        verify(
          () => shorebirdYamlFile.writeAsStringSync(
            any(
              that: contains('''
app_id: ${appIds[0]}
flavors:
  development: ${appIds[1]}
  developmentInternal: ${appIds[2]}
  production: ${appIds[3]}
  productionInternal: ${appIds[4]}
  staging: ${appIds[5]}
  stagingInternal: ${appIds[6]}'''),
            ),
          ),
        );
        verifyInOrder([
          () => codePushClientWrapper.createApp(
                appName: '$appName (development)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (developmentInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (production)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (productionInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (staging)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (stagingInternal)',
              ),
        ]);
      });

      test('ios + android w/same variants', () async {
        final appIds = [
          'test-appId-1',
          'test-appId-2',
          'test-appId-3',
          'test-appId-4',
          'test-appId-5',
          'test-appId-6'
        ];
        const variants = {
          'development',
          'developmentInternal',
          'production',
          'productionInternal',
          'staging',
          'stagingInternal',
        };
        var index = 0;
        when(
          () => gradlew.productFlavors(any()),
        ).thenAnswer((_) async => variants);
        when(() => xcodeBuild.list(any())).thenAnswer(
          (_) async => const XcodeProjectBuildInfo(schemes: variants),
        );
        when(
          () => codePushClientWrapper.createApp(appName: any(named: 'appName')),
        ).thenAnswer((invocation) async {
          final appName = invocation.namedArguments[#appName] as String?;
          return App(id: appIds[index++], displayName: appName ?? '-');
        });
        await runWithOverrides(command.run);
        verify(
          () => shorebirdYamlFile.writeAsStringSync(
            any(
              that: contains('''
app_id: ${appIds[0]}
flavors:
  development: ${appIds[0]}
  developmentInternal: ${appIds[1]}
  production: ${appIds[2]}
  productionInternal: ${appIds[3]}
  staging: ${appIds[4]}
  stagingInternal: ${appIds[5]}'''),
            ),
          ),
        );
        verifyInOrder([
          () => codePushClientWrapper.createApp(
                appName: '$appName (development)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (developmentInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (production)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (productionInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (staging)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (stagingInternal)',
              ),
        ]);
      });

      test('ios + android w/different variants', () async {
        final appIds = [
          'test-appId-1',
          'test-appId-2',
          'test-appId-3',
          'test-appId-4',
          'test-appId-5',
          'test-appId-6',
          'test-appId-7',
          'test-appId-8',
        ];
        const androidVariants = {
          'dev',
          'devInternal',
          'production',
          'productionInternal',
        };
        const iosVariants = {
          'development',
          'developmentInternal',
          'production',
          'productionInternal',
          'staging',
          'stagingInternal',
        };
        var index = 0;
        when(
          () => gradlew.productFlavors(any()),
        ).thenAnswer((_) async => androidVariants);
        when(() => xcodeBuild.list(any())).thenAnswer(
          (_) async => const XcodeProjectBuildInfo(schemes: iosVariants),
        );
        when(
          () => codePushClientWrapper.createApp(appName: any(named: 'appName')),
        ).thenAnswer((invocation) async {
          final appName = invocation.namedArguments[#appName] as String?;
          return App(id: appIds[index++], displayName: appName ?? '-');
        });
        await runWithOverrides(command.run);
        verify(
          () => shorebirdYamlFile.writeAsStringSync(
            any(
              that: contains('''
app_id: test-appId-1
flavors:
  dev: test-appId-1
  devInternal: test-appId-2
  production: test-appId-3
  productionInternal: test-appId-4
  development: test-appId-5
  developmentInternal: test-appId-6
  staging: test-appId-7
  stagingInternal: test-appId-8'''),
            ),
          ),
        );
        verifyInOrder([
          () => codePushClientWrapper.createApp(appName: '$appName (dev)'),
          () => codePushClientWrapper.createApp(
                appName: '$appName (devInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (production)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (productionInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (development)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (developmentInternal)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (staging)',
              ),
          () => codePushClientWrapper.createApp(
                appName: '$appName (stagingInternal)',
              ),
        ]);
      });
    });

    test('detects existing shorebird.yaml in pubspec.yaml assets', () async {
      when(() => pubspecYamlFile.readAsStringSync()).thenReturn('''
$pubspecYamlContent
flutter:
  assets:
    - shorebird.yaml
''');
      await runWithOverrides(command.run);
      verify(
        () => shorebirdYamlFile.writeAsStringSync(
          any(that: contains('app_id: $appId')),
        ),
      );
    });

    test('creates flutter.assets and adds shorebird.yaml', () async {
      await runWithOverrides(command.run);
      verify(
        () => pubspecYamlFile.writeAsStringSync(
          any(
            that: equals('''
$pubspecYamlContent
flutter:
  assets:
    - shorebird.yaml
'''),
          ),
        ),
      );
    });

    test('creates assets and adds shorebird.yaml', () async {
      when(() => pubspecYamlFile.readAsStringSync()).thenReturn('''
$pubspecYamlContent
flutter:
  uses-material-design: true
''');
      await runWithOverrides(command.run);
      verify(
        () => pubspecYamlFile.writeAsStringSync(
          any(
            that: equals('''
$pubspecYamlContent
flutter:
  assets:
    - shorebird.yaml
  uses-material-design: true
'''),
          ),
        ),
      );
    });

    test('adds shorebird.yaml to assets', () async {
      when(() => pubspecYamlFile.readAsStringSync()).thenReturn('''
$pubspecYamlContent
flutter:
  assets:
    - some/asset.txt
''');
      await runWithOverrides(command.run);
      verify(
        () => pubspecYamlFile.writeAsStringSync(
          any(
            that: equals('''
$pubspecYamlContent
flutter:
  assets:
    - some/asset.txt
    - shorebird.yaml
'''),
          ),
        ),
      ).called(1);
    });

    test('fixes fixable validation errors', () async {
      await runWithOverrides(command.run);
      verify(() => doctor.runValidators(any(), applyFixes: true)).called(1);
    });
  });
}
