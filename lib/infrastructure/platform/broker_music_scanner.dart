import 'package:flutter/services.dart';

import '../../app/music/music_scan_port.dart';
import '../../app/sync/sync_status_view_model.dart';
import 'broker_local_object_store.dart';

/// Native scanner adapter used by the app composition root. It forwards only
/// the opaque grant identity; native code returns normalized relative records.
final class BrokerMusicScanner implements MusicScannerPort {
  const BrokerMusicScanner({required this.channel});

  final BrokerMethodChannel channel;

  @override
  Future<Map<Object?, Object?>> scan(RootGrant grant) async {
    try {
      final value = await channel.invokeMethod<Object?>(
        'scanMusic',
        <String, Object?>{'token': grant.token, 'generation': grant.generation},
      );
      if (value is! Map) {
        throw const FormatException(
          'Native scanner returned a non-map response.',
        );
      }
      return value.cast<Object?, Object?>();
    } on PlatformException catch (error) {
      // Preserve the native error code for MusicScanController's user-facing
      // state and for callers that need to distinguish a revoked root.
      throw BrokerError(
        error.code,
        error.message ?? 'Native scan failed.',
        error.details,
      );
    } on MissingPluginException catch (error) {
      throw BrokerError(
        'unavailable',
        error.message ?? 'Native scanner is unavailable.',
      );
    }
  }
}
