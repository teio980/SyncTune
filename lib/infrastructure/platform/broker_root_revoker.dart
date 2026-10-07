import 'package:flutter/services.dart';

import '../../app/sync/sync_status_view_model.dart';
import 'broker_local_object_store.dart';

/// Calls native revokeRoot and reports whether persisted broker state was
/// confirmed empty. A `needs_rescan` result keeps the UI grant visible while
/// native operations are already stopped by the cleared generation record.
final class BrokerRootRevoker {
  const BrokerRootRevoker({required this.channel});

  final BrokerMethodChannel channel;

  Future<bool> revoke(RootGrant grant) async {
    try {
      final raw = await channel.invokeMethod<Object?>(
        'revokeRoot',
        <String, Object?>{'token': grant.token, 'generation': grant.generation},
      );
      if (raw is! Map) return false;
      final response = raw.cast<Object?, Object?>();
      return response['status'] == 'ok' &&
          (response['persisted'] == 'revoked' ||
              response['persisted'] == 'none');
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
