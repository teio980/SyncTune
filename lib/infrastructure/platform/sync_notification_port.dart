import 'dart:io' show Platform;

import '../../app/localization/strings.dart';
import '../../app/localization/webdav_strings.dart';
import 'broker_local_object_store.dart';

abstract interface class SyncNotificationPort {
  Future<void> onSyncStarted({required String title, required String message});

  Future<void> onSyncProgress({
    required String title,
    required String message,
    int? progress,
    int? max,
    bool indeterminate = false,
  });

  Future<void> onSyncFinished({
    required String title,
    required String message,
    required bool success,
  });

  Future<void> onSyncCancelled();

  Future<void> requestPermission();
}

final class PlatformSyncNotificationPort implements SyncNotificationPort {
  PlatformSyncNotificationPort({
    required this.channel,
    bool? isAndroid,
    this.languageProvider,
  }) : _isAndroid = isAndroid ?? Platform.isAndroid;

  final BrokerMethodChannel channel;
  final bool _isAndroid;
  final String Function()? languageProvider;

  bool get isAndroid => _isAndroid;

  String translate(String text) {
    final lang = languageProvider?.call() ??
        (Platform.localeName.startsWith('zh') ? 'zh' : 'en');
    if (lang == 'zh') {
      return SyncTuneStrings.chinese[text] ??
          webDavChinese[text] ??
          text;
    }
    return text;
  }

  @override
  Future<void> onSyncStarted({
    required String title,
    required String message,
  }) async {
    if (!_isAndroid) return;
    try {
      await channel.invokeMethod<Object?>(
        'syncNotificationStart',
        <String, Object?>{
          'title': translate(title),
          'message': translate(message),
        },
      );
    } catch (_) {}
  }

  @override
  Future<void> onSyncProgress({
    required String title,
    required String message,
    int? progress,
    int? max,
    bool indeterminate = false,
  }) async {
    if (!_isAndroid) return;
    try {
      await channel.invokeMethod<Object?>(
        'syncNotificationUpdate',
        <String, Object?>{
          'title': translate(title),
          'message': translate(message),
          if (progress != null) 'progress': progress,
          if (max != null) 'max': max,
          'indeterminate': indeterminate,
        },
      );
    } catch (_) {}
  }

  @override
  Future<void> onSyncFinished({
    required String title,
    required String message,
    required bool success,
  }) async {
    if (!_isAndroid) return;
    try {
      await channel.invokeMethod<Object?>(
        'syncNotificationFinish',
        <String, Object?>{
          'title': translate(title),
          'message': translate(message),
          'success': success,
        },
      );
    } catch (_) {}
  }

  @override
  Future<void> onSyncCancelled() async {
    if (!_isAndroid) return;
    try {
      await channel.invokeMethod<Object?>('syncNotificationCancel');
    } catch (_) {}
  }

  @override
  Future<void> requestPermission() async {
    if (!_isAndroid) return;
    try {
      await channel.invokeMethod<Object?>('requestNotificationPermission');
    } catch (_) {}
  }
}
