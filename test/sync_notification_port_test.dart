import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/infrastructure/platform/broker_local_object_store.dart';
import 'package:synctune/infrastructure/platform/sync_notification_port.dart';

final class FakeBrokerMethodChannel implements BrokerMethodChannel {
  final List<String> methods = <String>[];
  final List<Object?> arguments = <Object?>[];

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    methods.add(method);
    this.arguments.add(arguments);
    return null;
  }
}

void main() {
  group('PlatformSyncNotificationPort on Android', () {
    late FakeBrokerMethodChannel channel;
    late PlatformSyncNotificationPort port;

    setUp(() {
      channel = FakeBrokerMethodChannel();
      port = PlatformSyncNotificationPort(
        channel: channel,
        isAndroid: true,
        languageProvider: () => 'zh',
      );
    });

    test('onSyncStarted invokes native start with translated text', () async {
      await port.onSyncStarted(
        title: 'SyncTune Syncing',
        message: 'Checking sync requirements',
      );

      expect(channel.methods, ['syncNotificationStart']);
      final args = channel.arguments.single as Map<String, Object?>;
      expect(args['title'], 'SyncTune 同步中');
      expect(args['message'], '正在检查同步条件');
    });

    test('onSyncProgress invokes native update with progress parameters', () async {
      await port.onSyncProgress(
        title: 'SyncTune Syncing',
        message: 'Uploading',
        progress: 3,
        max: 10,
        indeterminate: false,
      );

      expect(channel.methods, ['syncNotificationUpdate']);
      final args = channel.arguments.single as Map<String, Object?>;
      expect(args['title'], 'SyncTune 同步中');
      expect(args['message'], '正在上传');
      expect(args['progress'], 3);
      expect(args['max'], 10);
      expect(args['indeterminate'], false);
    });

    test('onSyncFinished invokes native finish with success flag', () async {
      await port.onSyncFinished(
        title: 'SyncTune Sync complete',
        message: 'Music sync completed successfully',
        success: true,
      );

      expect(channel.methods, ['syncNotificationFinish']);
      final args = channel.arguments.single as Map<String, Object?>;
      expect(args['title'], 'SyncTune 同步完成');
      expect(args['message'], '音乐已同步完成');
      expect(args['success'], true);
    });

    test('onSyncCancelled invokes native cancel', () async {
      await port.onSyncCancelled();

      expect(channel.methods, ['syncNotificationCancel']);
    });

    test('requestPermission invokes native request', () async {
      await port.requestPermission();

      expect(channel.methods, ['requestNotificationPermission']);
    });
  });

  group('PlatformSyncNotificationPort on Windows (isAndroid: false)', () {
    late FakeBrokerMethodChannel channel;
    late PlatformSyncNotificationPort port;

    setUp(() {
      channel = FakeBrokerMethodChannel();
      port = PlatformSyncNotificationPort(
        channel: channel,
        isAndroid: false,
      );
    });

    test('all operations are complete no-ops without any channel invocations', () async {
      await port.onSyncStarted(title: 'SyncTune', message: 'Syncing');
      await port.onSyncProgress(title: 'SyncTune', message: 'Syncing', progress: 1, max: 2);
      await port.onSyncFinished(title: 'SyncTune', message: 'Done', success: true);
      await port.onSyncCancelled();
      await port.requestPermission();

      expect(channel.methods, isEmpty);
      expect(channel.arguments, isEmpty);
    });
  });
}
