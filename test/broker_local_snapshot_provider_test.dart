import 'package:flutter_test/flutter_test.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import 'package:synctune/infrastructure/platform/broker_local_object_store.dart';
import 'package:synctune/data/broker_local_snapshot_provider.dart';

const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final class _Root implements BrokerRootPort {
  _Root(this.current);

  @override
  BrokerRoot? current;
}

final class _Scanner implements BrokerLocalScanPort {
  _Scanner(this.response, {this.onScan});

  final Map<Object?, Object?> response;
  final void Function()? onScan;

  @override
  Future<Map<Object?, Object?>> scan(
    BrokerRoot root, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    onScan?.call();
    return response;
  }
}

final class _Catalog implements LocalCatalogStore {
  @override
  Future<String> ensureEntryId(SyncRoot root, SyncPath path) async =>
      'catalog-id';
}

final class _HashObjects implements LocalObjectStore {
  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) async => Stream<List<int>>.fromIterable(const <List<int>>[
    <int>[97, 98],
    <int>[99],
  ]);

  @override
  Future<StagedObject> stage(
    SyncPath path,
    Stream<List<int>> content, {
    required String expectedSha256,
    CancellationToken token = const NeverCancelled(),
  }) => throw UnimplementedError();

  @override
  Future<Stream<List<int>>> openStaged(
    StagedObject staged, {
    CancellationToken token = const NeverCancelled(),
  }) => throw UnimplementedError();

  @override
  Future<bool> verifyStaged(
    StagedObject staged, {
    required String expectedSha256,
    required int expectedLength,
    CancellationToken token = const NeverCancelled(),
  }) => throw UnimplementedError();

  @override
  Future<void> commitStaged(
    SyncPath path,
    StagedObject staged, {
    required SyncEntry entry,
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) => throw UnimplementedError();

  @override
  Future<void> delete(
    SyncPath path, {
    required LocalCondition condition,
    SyncEntry? tombstone,
    String? operationId,
    CancellationToken token = const NeverCancelled(),
  }) => throw UnimplementedError();

  @override
  Future<void> saveTombstone(
    SyncPath path,
    SyncEntry tombstone, {
    CancellationToken token = const NeverCancelled(),
  }) => throw UnimplementedError();

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    CancellationToken token = const NeverCancelled(),
  }) => throw UnimplementedError();
}

Map<Object?, Object?> _item({String id = 'stable-id'}) => <Object?, Object?>{
  'id': id,
  'relativePath': 'album/song.mp3',
  'size': 3,
  'sha256': _hash,
  'modifiedAtUtc': '2026-10-06T12:00:00Z',
  'favorite': true,
  'favoriteLamport': 4,
  'favoriteDeviceId': 'device-a',
};

void main() {
  const syncRoot = SyncRoot('root', generation: 'generation-1');

  test('converts a complete broker scan into a hashed snapshot', () async {
    final active = _Root(
      const BrokerRoot(token: 'opaque-1', generation: 'generation-1'),
    );
    final provider = BrokerLocalSnapshotProvider(
      root: active,
      scanner: _Scanner(<Object?, Object?>{
        'status': 'ok',
        'generation': 'generation-1',
        'complete': true,
        'items': <Object?>[_item()],
      }),
      deviceId: 'device-local',
      nowUtc: () => DateTime.utc(2026, 10, 6, 12, 1),
    );

    final snapshot = await provider.capture(syncRoot);
    expect(snapshot.complete, isTrue);
    expect(snapshot.deviceId, 'device-local');
    final entry = snapshot.entries[SyncPath.parse('album/song.mp3')]!;
    expect(entry.id, 'stable-id');
    expect(entry.sha256, _hash);
    expect(entry.favorite.deviceId, 'device-a');
  });

  test('publishes partial scans as partial snapshots', () async {
    final active = _Root(
      const BrokerRoot(token: 'opaque-1', generation: 'generation-1'),
    );
    final provider = BrokerLocalSnapshotProvider(
      root: active,
      scanner: _Scanner(<Object?, Object?>{
        'status': 'ok',
        'generation': 'generation-1',
        'complete': false,
        'items': <Object?>[_item()],
      }),
      deviceId: 'device-local',
    );

    final snapshot = await provider.capture(syncRoot);
    expect(snapshot.completeness, ScanCompleteness.partial);
  });

  test('rejects an item without stable identity or hash', () async {
    final active = _Root(
      const BrokerRoot(token: 'opaque-1', generation: 'generation-1'),
    );
    final provider = BrokerLocalSnapshotProvider(
      root: active,
      scanner: _Scanner(<Object?, Object?>{
        'status': 'ok',
        'generation': 'generation-1',
        'complete': true,
        'items': <Object?>[
          <Object?, Object?>{'relativePath': 'song.mp3', 'size': 3},
        ],
      }),
      deviceId: 'device-local',
    );

    await expectLater(provider.capture(syncRoot), throwsA(isA<NeedsRescan>()));
  });

  test('drops a scan whose root changes before it returns', () async {
    final active = _Root(
      const BrokerRoot(token: 'opaque-1', generation: 'generation-1'),
    );
    final provider = BrokerLocalSnapshotProvider(
      root: active,
      scanner: _Scanner(
        <Object?, Object?>{
          'status': 'ok',
          'generation': 'generation-1',
          'complete': true,
          'items': <Object?>[_item()],
        },
        onScan: () {
          active.current = const BrokerRoot(
            token: 'opaque-2',
            generation: 'generation-2',
          );
        },
      ),
      deviceId: 'device-local',
    );

    await expectLater(provider.capture(syncRoot), throwsA(isA<NeedsRescan>()));
  });

  test(
    'enriches legacy scan records from private catalog and broker hash',
    () async {
      final active = _Root(
        const BrokerRoot(token: 'opaque-1', generation: 'generation-1'),
      );
      final provider = BrokerLocalSnapshotProvider(
        root: active,
        scanner: _Scanner(<Object?, Object?>{
          'status': 'ok',
          'generation': 'generation-1',
          'complete': true,
          'items': <Object?>[
            <Object?, Object?>{'relativePath': 'album/song.mp3', 'size': 3},
          ],
        }),
        catalog: _Catalog(),
        objects: _HashObjects(),
        deviceId: 'device-local',
      );

      final snapshot = await provider.capture(syncRoot);
      final entry = snapshot.entries[SyncPath.parse('album/song.mp3')]!;
      expect(entry.id, 'catalog-id');
      expect(
        entry.sha256,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    },
  );
}
