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
    'SAF recovery capabilities remain distinct from atomic CAS',
    () async {
      final capabilities = await MethodChannelBrokerCapabilities(
        channel: _CapabilitiesChannel(<String, Object?>{
          'status': 'ok',
          'platform': 'android',
          'credentials': 'android_keystore_aes_gcm_app_private',
          'staging': 'persistent_after_finish_root_scoped',
          'atomicCreate': 'verified_create_recovery',
          'conditionalReplace': 'verified_backup_replace',
          'conditionalDelete': 'verified_backup_delete',
          'temporaryPermission': 'not_verifiable',
        }),
      ).read();
      expect(capabilities.canCreateOnly, isFalse);
      expect(capabilities.canConditionalReplace, isFalse);
      expect(capabilities.canConditionalDelete, isFalse);
      expect(capabilities.canVerifiedCreate, isTrue);
      expect(capabilities.canVerifiedBackupReplace, isTrue);
      expect(capabilities.canVerifiedBackupDelete, isTrue);
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
