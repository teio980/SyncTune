import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synctune/data/sync_tune_database.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

void main() {
  test('private state persists device identity, Lamport clock, settings and catalog', () async {
    final database = SyncTuneDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final root = const SyncRoot('music-root', generation: 'generation-1');
    final path = SyncPath.parse('album/song.mp3');

    final device = await database.loadOrCreateDeviceId();
    expect(device, startsWith('device-'));
    expect(await database.loadOrCreateDeviceId(), device);
    expect(await database.nextLamport(), 1);
    expect(await database.nextLamport(), 2);

    await database.saveSetting('themeMode', 'system');
    expect(await database.loadSetting('themeMode'), 'system');
    await database.deleteSetting('themeMode');
    expect(await database.loadSetting('themeMode'), isNull);

    final entryId = await database.ensureCatalogEntryId(root, path);
    expect(await database.loadCatalogEntryId(root, path), entryId);
    expect(
      await database.loadCatalogEntryId(
        const SyncRoot('music-root', generation: 'generation-2'),
        path,
      ),
      isNull,
    );

    final entry = SyncEntry.file(
      id: entryId,
      path: path,
      size: 3,
      modifiedAtUtc: DateTime.utc(2026),
      sha256: 'a' * 64,
    );
    await database.rememberEntry(root, entry);
    expect((await database.loadCatalogEntry(root, path))!.id, entryId);
    final renamed = SyncEntry.file(
      id: entryId,
      path: SyncPath.parse('renamed.mp3'),
      size: 3,
      modifiedAtUtc: DateTime.utc(2026),
      sha256: 'a' * 64,
    );
    await database.rememberEntry(root, renamed);
    expect((await database.loadCatalogEntry(root, path))!.isDeleted, isTrue);
    expect((await database.loadCatalogEntry(root, renamed.path))!.id, entryId);
    final tombstone = SyncEntry.tombstone(
      id: entryId,
      path: renamed.path,
      modifiedAtUtc: DateTime.utc(2026, 1, 2),
      revision: 2,
    );
    await database.rememberEntry(root, tombstone);
    expect(
      (await database.loadCatalogEntry(root, renamed.path))!.isDeleted,
      isTrue,
    );
  });

  test('Drift metadata store keeps favorite Lamport ordering', () async {
    final database = SyncTuneDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    await database.saveFavorite(
      entryId: 'entry-1',
      relativePath: 'album/song.mp3',
      value: true,
      lamport: 4,
      deviceId: 'device-a',
    );
    await database.saveFavorite(
      entryId: 'entry-1',
      relativePath: 'album/song.mp3',
      value: false,
      lamport: 3,
      deviceId: 'device-z',
    );
    final rows = await database
        .customSelect('SELECT value, lamport, device_id FROM favorites')
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.read<int>('value'), 1);
    expect(rows.single.read<int>('lamport'), 4);
    expect(rows.single.read<String>('device_id'), 'device-a');
  });

  test('Drift favorite stream emits persisted rows', () async {
    final database = SyncTuneDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final values = <List<FavoriteRow>>[];
    final subscription = database.watchFavorites().listen(values.add);
    addTearDown(subscription.cancel);

    await database.saveFavorite(
      entryId: 'entry-2',
      relativePath: 'song.flac',
      value: true,
      lamport: 1,
      deviceId: 'device-a',
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      values.any(
        (rows) => rows.any((row) => row.entryId == 'entry-2' && row.value),
      ),
      isTrue,
    );
  });

  test(
    'Drift persists generation-scoped baselines and journal records',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final root = const SyncRoot('music-root', generation: 'generation-1');
      final now = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final entry = SyncEntry.file(
        id: 'entry-1',
        path: SyncPath.parse('album/song.mp3'),
        size: 7,
        modifiedAtUtc: now,
        sha256: 'a' * 64,
        favorite: const FavoriteStamp(
          value: true,
          lamport: 2,
          deviceId: 'device-a',
        ),
      );
      await database.saveConfirmed(
        root,
        SyncSnapshot(
          deviceId: 'device-a',
          capturedAtUtc: now,
          entries: [entry],
          generation: root.generation,
        ),
        planId: 'plan-1',
      );
      final loaded = await database.load(root);
      expect(loaded, isNotNull);
      expect(
        loaded!.entries[SyncPath.parse('album/song.mp3')]!.sha256,
        'a' * 64,
      );
      expect(
        await database.load(
          const SyncRoot('music-root', generation: 'generation-2'),
        ),
        isNull,
      );

      await database.append(
        JournalRecord(
          planId: 'plan-1',
          generation: root.generation,
          operationId: 'operation-1',
          path: SyncPath.parse('album/song.mp3'),
          state: JournalState.staged,
          atUtc: now,
          stagingKey: 'stage-1',
          sha256: 'a' * 64,
          length: 7,
          condition: 'local-sha256:${'a' * 64}',
          metadataCondition: 'If-Match:"metadata-1"',
          error: null,
        ),
      );
      final records = await database.recordsFor('plan-1', root.generation);
      expect(records, hasLength(1));
      expect(records.single.stagingKey, 'stage-1');
      expect(records.single.metadataCondition, 'If-Match:"metadata-1"');
    },
  );

  test('Drift refuses partial or cross-generation baselines', () async {
    final database = SyncTuneDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final root = const SyncRoot('music-root', generation: 'generation-1');
    final partial = SyncSnapshot(
      deviceId: 'device-a',
      capturedAtUtc: DateTime.utc(2026),
      entries: const <SyncEntry>[],
      completeness: ScanCompleteness.partial,
      generation: root.generation,
    );
    await expectLater(
      database.saveConfirmed(root, partial, planId: 'partial-plan'),
      throwsA(isA<NeedsRescan>()),
    );
    await expectLater(
      database.saveConfirmed(
        root,
        SyncSnapshot(
          deviceId: 'device-a',
          capturedAtUtc: DateTime.utc(2026),
          entries: const <SyncEntry>[],
          generation: 'generation-2',
        ),
        planId: 'wrong-generation',
      ),
      throwsStateError,
    );
  });

  test('remote namespace changes isolate confirmed baselines', () async {
    final database = SyncTuneDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final first = const SyncRoot(
      'music-root',
      generation: 'generation-1',
      remoteNamespace: 'server-a/music',
    );
    await database.saveConfirmed(
      first,
      SyncSnapshot(
        deviceId: 'device-a',
        capturedAtUtc: DateTime.utc(2026),
        entries: const <SyncEntry>[],
        generation: first.generation,
      ),
      planId: 'server-a-plan',
    );
    final second = const SyncRoot(
      'music-root',
      generation: 'generation-1',
      remoteNamespace: 'server-b/music',
    );
    expect(await database.load(second), isNull);
  });

  test(
    'Drift journal keeps staged and committed rows in append order',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final path = SyncPath.parse('song.mp3');
      final later = DateTime.utc(2026, 2);
      final earlier = DateTime.utc(2026, 1);
      JournalRecord record(JournalState state, DateTime at) => JournalRecord(
        planId: 'plan-order',
        generation: 'generation-1',
        operationId: 'operation-1',
        path: path,
        state: state,
        atUtc: at,
        stagingKey: 'stage-1',
        sha256: 'b' * 64,
        length: 3,
        condition: 'local-absent',
        error: null,
      );
      await database.append(record(JournalState.staged, later));
      await database.append(record(JournalState.committed, earlier));
      final records = await database.recordsFor('plan-order', 'generation-1');
      expect(records.map((value) => value.state), [
        JournalState.staged,
        JournalState.committed,
      ]);
    },
  );

  test(
    'durable plans round-trip all operation identity and conditions',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const root = SyncRoot(
        'music-root',
        generation: 'generation-1',
        remoteNamespace: 'server-a/music',
      );
      final path = SyncPath.parse('album/song.mp3');
      final entry = SyncEntry.file(
        id: 'stable-entry',
        path: path,
        size: 3,
        modifiedAtUtc: DateTime.utc(2026, 1, 2),
        sha256: 'a' * 64,
        etag: '"content"',
        revision: 4,
        favorite: const FavoriteStamp(
          value: true,
          lamport: 7,
          deviceId: 'remote-device',
        ),
      );
      final plan = SyncPlan(
        planId: 'plan-1',
        generation: root.generation,
        remoteNamespace: root.remoteNamespace,
        deletionsSuppressed: false,
        operations: [
          SyncOperation(
            id: 'operation-1',
            kind: SyncOperationKind.putLocalToRemote,
            path: path,
            planId: 'plan-1',
            generation: root.generation,
            source: entry,
            other: entry,
            condition: MatchEtag('"content"'),
            metadataCondition: MatchEtag('"metadata"'),
            localCondition: LocalMatchSha256('a' * 64),
            preservePath: SyncPath.parse('album/song-conflict.mp3'),
            expectedLocalSha256: 'a' * 64,
          ),
        ],
      );
      await database.savePlan(root, plan);
      final restored = await database.loadUnfinishedPlan(root);
      expect(restored, isNotNull);
      expect(SyncPlanCodec.toJson(restored!), SyncPlanCodec.toJson(plan));
      await database.markPlanFinished(root, plan.planId);
      expect(await database.loadUnfinishedPlan(root), isNull);
    },
  );

  test(
    'baseline retains a rename tombstone sharing the live identity',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const root = SyncRoot('music-root', generation: 'generation-1');
      final oldPath = SyncPath.parse('old/song.mp3');
      final newPath = SyncPath.parse('new/song.mp3');
      final tombstone = SyncEntry.tombstone(
        id: 'stable-song',
        path: oldPath,
        modifiedAtUtc: DateTime.utc(2026),
        revision: 2,
      );
      final live = SyncEntry.file(
        id: 'stable-song',
        path: newPath,
        size: 1,
        modifiedAtUtc: DateTime.utc(2026),
        sha256: 'a' * 64,
      );
      await database.saveConfirmed(
        root,
        SyncSnapshot(
          deviceId: 'device-a',
          capturedAtUtc: DateTime.utc(2026),
          entries: [tombstone, live],
          generation: root.generation,
        ),
        planId: 'rename-tombstone',
      );
      final restored = await database.load(root);
      expect(restored!.entries[oldPath]!.isDeleted, isTrue);
      expect(restored.entries[newPath]!.id, 'stable-song');
    },
  );
}
