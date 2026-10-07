import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/infrastructure/platform/broker_credentials.dart';
import 'package:synctune/infrastructure/platform/broker_local_object_store.dart';

final class _CredentialChannel implements BrokerMethodChannel {
  final calls = <String>[];
  final arguments = <String, Map<String, Object?>>{};
  final values = <String, String>{};
  bool deny = false;

  String _key(Map<String, Object?> map) =>
      '${map['service']}:${map['account']}';

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(method);
    final map = (arguments as Map).cast<String, Object?>();
    this.arguments[method] = map;
    if (deny) {
      throw PlatformException(code: 'denied', message: 'credential rejected');
    }
    final key = _key(map);
    switch (method) {
      case 'credentialSave':
        values[key] = map['secret']! as String;
        return <String, Object?>{'status': 'ok', 'stored': true} as T;
      case 'credentialRead':
        final value = values[key];
        return <String, Object?>{
          'status': 'ok',
          'found': value != null,
          ...?value == null ? null : <String, Object?>{'secret': value},
        } as T;
      case 'credentialDelete':
        values.remove(key);
        return <String, Object?>{'status': 'ok', 'deleted': true} as T;
      default:
        return <String, Object?>{} as T;
    }
  }
}

void main() {
  test('credential keys normalize consistently and round trip', () async {
    final channel = _CredentialChannel();
    final store = MethodChannelBrokerCredentialStore(channel: channel);

    await store.save(
      service: '  WebDAV  ',
      account: ' User ',
      secret: 'opaque-secret',
    );
    expect(channel.arguments['credentialSave'], <String, Object?>{
      'service': 'webdav',
      'account': 'user',
      'secret': 'opaque-secret',
    });
    expect(
      await store.read(service: 'WEBDAV', account: 'USER'),
      'opaque-secret',
    );
    await store.delete(service: 'webdav', account: 'user');
    expect(await store.read(service: 'webdav', account: 'user'), isNull);
  });

  test('invalid key is rejected before native IPC', () async {
    final channel = _CredentialChannel();
    final store = MethodChannelBrokerCredentialStore(channel: channel);
    await expectLater(
      store.read(service: 'bad/service', account: 'user'),
      throwsA(isA<CredentialBrokerError>()),
    );
    expect(channel.calls, isEmpty);
  });

  test('platform denial does not expose a secret in the error', () async {
    final channel = _CredentialChannel()..deny = true;
    final store = MethodChannelBrokerCredentialStore(channel: channel);
    await expectLater(
      store.save(service: 'service', account: 'account', secret: 'do-not-leak'),
      throwsA(
        predicate<Object>(
          (error) =>
              error is CredentialBrokerError &&
              !error.toString().contains('do-not-leak'),
        ),
      ),
    );
  });
}
