import '../sync/sync_status_view_model.dart';

/// Native/platform composition supplies the broker-backed implementation.
/// The app receives normalized records and never traverses a user path.
abstract interface class MusicScannerPort {
  Future<Map<Object?, Object?>> scan(RootGrant grant);
}

/// A scanner record returned by a platform adapter.
typedef MusicScanRecord = Map<Object?, Object?>;
