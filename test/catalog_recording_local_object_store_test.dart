import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/data/catalog_recording_local_object_store.dart';
import 'package:synctune/data/broker_local_snapshot_provider.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

void main() {
  const oldRoot = SyncRoot('root', generation: 'generation-1');
  const newRoot = SyncRoot('root', generation: 'generation-2');
  final path = SyncPath.parse('song.mp3');
  final entry = SyncEntry.file(
    id: 'stable-song',
    path: path,
    size: 1,
    modifiedAtUtc: DateTime.utc(2026),
    sha256: 'a' * 64,
  );

  test(
    'delete stops after catalog read when the root generation changes',
    () async {
      final catalog = _Catalog()..entries[path.value] = entry;
      final delegate = _Store();
      var reads = 0;
      final store = CatalogRecordingLocalObjectStore(
        delegate: delegate,
        catalog: catalog,
        activeRoot: () => ++reads >= 3 ? newRoot : oldRoot,
      );

      await expectLater(
        store.delete(path, condition: LocalMatchSha256(entry.sha256!)),
        throwsA(isA<NeedsRescan>()),
      );
      expect(delegate.deleteCalls, 0);
    },
  );

  test(
    'favorite update stops after catalog read when the root generation changes',
    () async {
      final catalog = _Catalog()..entries[path.value] = entry;
      final delegate = _Store();
      var reads = 0;
      final store = CatalogRecordingLocalObjectStore(
        delegate: delegate,
        catalog: catalog,
        activeRoot: () => ++reads >= 3 ? newRoot : oldRoot,
      );

      await expectLater(
        store.updateFavorite(
          path,
          const FavoriteStamp(value: true, lamport: 1, deviceId: 'device'),
        ),
        throwsA(isA<NeedsRescan>()),
      );
      expect(catalog.favoriteWrites, 0);
    },
  );
}

final class _Catalog implements CatalogEntryStore {
  final entries = <String, SyncEntry>{};
  int favoriteWrites = 0;

  @override
  Future<String> ensureEntryId(SyncRoot root, SyncPath path) async =>
      entries[path.value]?.id ?? 'generated';

  @override
  Future<void> rememberEntry(SyncRoot root, SyncEntry entry) async {
    entries[entry.path.value] = entry;
  }

  @override
  Future<SyncEntry?> loadCatalogEntry(SyncRoot root, SyncPath path) async =>
      entries[path.value];

  @override
  Future<List<SyncEntry>> loadCatalogEntries(SyncRoot root) async =>
      entries.values.toList(growable: false);

  @override
  Future<FavoriteStamp?> loadFavorite(String entryId) async => null;

  @override
  Future<void> saveCatalogFavorite(
    String entryId,
    SyncPath path,
    FavoriteStamp stamp,
  ) async {
    favoriteWrites++;
  }
}

final class _Store implements LocalObjectStore {
  int deleteCalls = 0;

  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) async => Stream<List<int>>.value(const <int>[1]);

  @override
  Future<StagedObject> stage(
    SyncPath path,
    Stream<List<int>> content, {
    required String expectedSha256,
    CancellationToken token = const NeverCancelled(),
  }) async => StagedObject(key: 'stage', sha256: expectedSha256, length: 1);

  @override
  Future<Stream<List<int>>> openStaged(
    StagedObject staged, {
    CancellationToken token = const NeverCancelled(),
  }) async => Stream<List<int>>.value(const <int>[1]);

  @override
  Future<bool> verifyStaged(
    StagedObject staged, {
    required String expectedSha256,
    required int expectedLength,
    CancellationToken token = const NeverCancelled(),
  }) async => true;

  @override
  Future<void> commitStaged(
    SyncPath path,
    StagedObject staged, {
    required SyncEntry entry,
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) async {}

  @override
  Future<void> delete(
    SyncPath path, {
    required LocalCondition condition,
    String? operationId,
    CancellationToken token = const NeverCancelled(),
  }) async {
    deleteCalls++;
  }

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    CancellationToken token = const NeverCancelled(),
  }) async {}
}
