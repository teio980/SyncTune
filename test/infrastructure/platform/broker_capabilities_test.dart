import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/infrastructure/platform/broker_capabilities.dart';
import 'package:synctune/infrastructure/platform/broker_local_object_store.dart';

final class _CapabilitiesChannel implements BrokerMethodChannel {
  _CapabilitiesChannel(this.value);

  final Object? value;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async =>
      value as T?;
}

void main() {
  test(
    'SAF capabilities expose conditional operations as unsupported',
    () async {
      final capabilities = await MethodChannelBrokerCapabilities(
        channel: _CapabilitiesChannel(<String, Object?>{
          'status': 'ok',
          'platform': 'android',
          'credentials': 'android_keystore_aes_gcm_app_private',
          'staging': 'persistent_after_finish_root_scoped',
          'atomicCreate': 'unsupported_saf_provider',
          'conditionalReplace': 'unsupported_saf_provider',
          'conditionalDelete': 'unsupported_saf_provider',
          'temporaryPermission': 'not_verifiable',
        }),
      ).read();
      expect(capabilities.canCreateOnly, isFalse);
      expect(capabilities.canConditionalReplace, isFalse);
      expect(capabilities.canConditionalDelete, isFalse);
      expect(capabilities.staging, 'persistent_after_finish_root_scoped');
    },
  );

  test('malformed capability response is a broker protocol error', () async {
    await expectLater(
      MethodChannelBrokerCapabilities(
        channel: _CapabilitiesChannel(<String, Object?>{'status': 'ok'}),
      ).read(),
      throwsA(isA<BrokerError>()),
    );
  });
}
