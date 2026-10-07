import 'package:synctune_sync_core/synctune_sync_core.dart';

import 'broker_local_snapshot_provider.dart';

/// Adds durable identity/catalog bookkeeping around a broker object store.
///
/// The broker remains the only component that reads or writes user files. The
/// decorator records the remote entry identity only after a conditional local
/// commit succeeds, and records a tombstone after a conditional local delete.
/// A root switch between the operation and catalog write stops the run rather
/// than attributing the result to a different authorization generation.
final class CatalogRecordingLocalObjectStore implements LocalObjectStore {
  CatalogRecordingLocalObjectStore({
    required this.delegate,
    required this.catalog,
    required this.activeRoot,
    DateTime Function()? nowUtc,
  }) : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final LocalObjectStore delegate;
  final CatalogEntryStore catalog;
  final SyncRoot Function() activeRoot;
  final DateTime Function() _nowUtc;

  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) => delegate.read(path, token: token);

  @override
  Future<StagedObject> stage(
    SyncPath path,
    Stream<List<int>> content, {
    required String expectedSha256,
    CancellationToken token = const NeverCancelled(),
  }) => delegate.stage(
    path,
    content,
    expectedSha256: expectedSha256,
    token: token,
  );

  @override
  Future<Stream<List<int>>> openStaged(
    StagedObject staged, {
    CancellationToken token = const NeverCancelled(),
  }) => delegate.openStaged(staged, token: token);

  @override
  Future<bool> verifyStaged(
    StagedObject staged, {
    required String expectedSha256,
    required int expectedLength,
    CancellationToken token = const NeverCancelled(),
  }) => delegate.verifyStaged(
    staged,
    expectedSha256: expectedSha256,
    expectedLength: expectedLength,
    token: token,
  );

  @override
  Future<void> commitStaged(
    SyncPath path,
    StagedObject staged, {
    required SyncEntry entry,
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final pinned = activeRoot();
    _ensurePinned(pinned, token);
    await delegate.commitStaged(
      path,
      staged,
      entry: entry,
      condition: condition,
      token: token,
    );
    _ensurePinned(pinned, token);
    await catalog.rememberEntry(pinned, entry);
    _ensurePinned(pinned, token);
    if (_shouldPersistFavorite(entry.favorite)) {
      await catalog.saveCatalogFavorite(entry.id, path, entry.favorite);
      _ensurePinned(pinned, token);
    }
  }

  @override
  Future<void> delete(
    SyncPath path, {
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final pinned = activeRoot();
    _ensurePinned(pinned, token);
    final previous = await catalog.loadCatalogEntry(pinned, path);
    _ensurePinned(pinned, token);
    if (previous == null || previous.isDeleted) {
      throw NeedsRescan('local delete has no catalog identity for $path');
    }
    await delegate.delete(path, condition: condition, token: token);
    _ensurePinned(pinned, token);
    await catalog.rememberEntry(
      pinned,
      SyncEntry.tombstone(
        id: previous.id,
        path: path,
        modifiedAtUtc: _nowUtc(),
        revision: previous.revision + 1,
        favorite: previous.favorite,
      ),
    );
    _ensurePinned(pinned, token);
  }

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    final pinned = activeRoot();
    _ensurePinned(pinned, token);
    final previous = await catalog.loadCatalogEntry(pinned, path);
    _ensurePinned(pinned, token);
    if (previous == null || previous.isDeleted) {
      throw NeedsRescan('local favorite has no catalog identity for $path');
    }
    // Favorites are private metadata, not file bytes. The broker object store
    // intentionally has no unconditional file-side favorite write; persist
    // the stamp in the durable DB and let the next snapshot merge it.
    await catalog.saveCatalogFavorite(previous.id, path, stamp);
    _ensurePinned(pinned, token);
    await catalog.rememberEntry(pinned, previous.copyWith(favorite: stamp));
    _ensurePinned(pinned, token);
  }

  void _ensurePinned(SyncRoot pinned, CancellationToken token) {
    token.throwIfCancelled();
    if (!_sameRoot(activeRoot(), pinned)) {
      throw const NeedsRescan('root changed during local mutation');
    }
  }

  bool _shouldPersistFavorite(FavoriteStamp stamp) =>
      stamp.value || stamp.lamport > 0 || stamp.deviceId.isNotEmpty;

  bool _sameRoot(SyncRoot left, SyncRoot right) =>
      left.id == right.id &&
      left.generation == right.generation &&
      left.remoteNamespace == right.remoteNamespace;
}
