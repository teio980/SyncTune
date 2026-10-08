import 'sync_model.dart';

/// Credentials are supplied by the operating system's secure credential store.
/// Implementations must not copy secrets into SyncSettings or SQLite.
abstract interface class SyncCredentialStore {
  Future<String> read(SyncSettings settings);
  Future<void> write(SyncSettings settings, String secret);
  Future<void> delete(SyncSettings settings);
}

/// Platform lifetime hook for Android's foreground data-sync service.
/// A failed start must throw so the controller never reports a background run
/// that the operating system did not actually start.
abstract interface class SyncExecutionHost {
  Future<void> start(SyncSettings settings);
  Future<void> update(SyncProgress progress);
  Future<void> finish(SyncProgress progress);
}

final class SyncFolderSelection {
  const SyncFolderSelection({
    required this.locator,
    required this.stableId,
    required this.generation,
  });

  /// A Windows absolute path or a platform-owned SAF document-tree token.
  final String locator;
  final String stableId;
  final String generation;
}

abstract interface class SyncFolderPicker {
  Future<SyncFolderSelection?> pick();
}

abstract interface class SyncMusicLibrary {
  Future<List<SyncMusicTrack>> listMusic(SyncSettings settings);
  Future<void> deleteMusic(SyncSettings settings, SyncMusicTrack track);
}
