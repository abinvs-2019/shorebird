import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:test/test.dart';

void main() {
  group(CreatePatchEventRequest, () {
    test('can be (de)serialized', () {
      final request = CreatePatchEventRequest(
        event: PatchInstallEvent(
          clientId: 'some-client-id',
          appId: 'some-app-id',
          patchNumber: 2,
          arch: 'arm64',
          platform: ReleasePlatform.android,
          releaseVersion: '1.0.0',
        ),
      );
      expect(
        CreatePatchEventRequest.fromJson(request.toJson()).toJson(),
        equals(request.toJson()),
      );
    });
  });
}
