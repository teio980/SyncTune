import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/sync/sync_gate.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';
import 'package:synctune/data/sync_tune_database.dart';
import 'package:synctune/infrastructure/composition/music_deletion_service.dart';
import 'package:synctune/infrastructure/composition/synctune_composition.dart';
import 'package:synctune/infrastructure/runtime/foreground_sync_runtime.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

void main() {
  late SyncTuneDatabase database;
  late _FakeLocalObjectStore localStore;
  late CompositionTargetPort targetPort;
  late _FakeRunner runner;
  late ForegroundSyncRuntime runtime;
  late SyncTuneMusicDeletionService service;

  final grant = RootGrant(
    path: '/music',
    token: 'root-token',
    generation: 'gen-1',
  );

  setUp(() {
    database = SyncTuneDatabase(NativeDatabase.memory());
    localStore = _FakeLocalObjectStore();
    targetPort = CompositionTargetPort(configEpoch: 'epoch-1');
    targetPort.setRoot(grant);
    runner = _FakeRunner();
    runtime = ForegroundSyncRuntime(
      targetPort: targetPort,
      runner: runner,
    );
    service = SyncTuneMusicDeletionService(
      database: database,
      local: localStore,
      targets: targetPort,
      runtime: runtime,
    );
  });

  tearDown(() async {
    await runtime.disposeAndWait();
    await database.close();
  });

  test('throws StateError when no target is active', () async {
    targetPort.setRoot(null);
    await expectLater(
      service.deleteSong(
        relativePath: 'song.mp3',
        expectedSha256: 'a' * 64,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('successfully deletes locally and updates deletion task stage', () async {
    const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    localStore.existingFiles['song.mp3'] = sha;

    await service.deleteSong(
      relativePath: 'song.mp3',
      expectedSha256: sha,
    );

    expect(localStore.deletedFiles, contains('song.mp3'));
    expect(localStore.savedTombstones, contains('song.mp3'));

    // Check task was saved and updated to local_deleted
    final pending = await service.pendingTasks();
    expect(pending, hasLength(1));
    expect(pending.first.relativePath, 'song.mp3');
    expect(pending.first.stage, 'local_deleted');
  });

  test('aborts without deleting when local sha256 does not match condition', () async {
    const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    localStore.existingFiles['song.mp3'] = 'different_sha';

    await expectLater(
      service.deleteSong(
        relativePath: 'song.mp3',
        expectedSha256: sha,
      ),
      throwsA(isA<NeedsRescan>()),
    );

    expect(localStore.deletedFiles, isEmpty);
  });

  test('cannot delete while another deletion/sync holds execution slot', () async {
    const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    localStore.existingFiles['song.mp3'] = sha;

    final blocker = Completer<void>();
    // Acquire the execution slot
    final exclusiveRun = runtime.runExclusive(() => blocker.future);

    // Deletion attempt while slot is occupied should fail
    await expectLater(
      service.deleteSong(
        relativePath: 'song.mp3',
        expectedSha256: sha,
      ),
      throwsA(isA<SyncRuntimeNotReady>()),
    );

    blocker.complete();
    await exclusiveRun;
  });

  test('recovers interrupted local deletion task on startup', () async {
    const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    localStore.existingFiles['pending.mp3'] = sha;

    // Seed task that stopped at pending_local
    await database.saveDeletionTask(DeletionTaskRecord(
      operationId: 'op-1',
      rootId: '${grant.token}|epoch-1',
      generation: grant.generation,
      remoteNamespace: 'epoch-1',
      entryId: 'entry-1',
      relativePath: 'pending.mp3',
      expectedSha256: sha,
      stage: 'pending_local',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    await service.recoverTasks();

    expect(localStore.deletedFiles, contains('pending.mp3'));
    final pending = await service.pendingTasks();
    expect(pending.first.stage, 'local_deleted');
  });

  test('does not recover tasks from different root or server', () async {
    // Seed task from a different root
    await database.saveDeletionTask(DeletionTaskRecord(
      operationId: 'op-other',
      rootId: 'other-root',
      generation: 'gen-x',
      remoteNamespace: 'epoch-x',
      entryId: 'entry-other',
      relativePath: 'other.mp3',
      expectedSha256: 'a' * 64,
      stage: 'pending_local',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    await service.recoverTasks();
    expect(localStore.deletedFiles, isEmpty);
  });
}

final class _FakeRunner implements ConfirmedSyncRunner {
  int runs = 0;
  bool shouldThrow = false;

  @override
  Future<SyncGateState> check(
    SyncRuntimeTarget target, {
    CancellationToken token = const NeverCancelled(),
  }) async =>
      const SyncGateState(
        status: SyncGateStatus.ready,
        title: 'Ready',
        message: 'Ready',
      );

  @override
  Future<SyncRunResult> run(
    SyncRuntimeTarget target, {
    required String runToken,
    CancellationToken token = const NeverCancelled(),
  }) async {
    runs++;
    if (shouldThrow) throw Exception('Network offline');
    return const SyncRunResult(
      plan: SyncPlan(
        planId: 'plan-1',
        generation: 'gen-1',
        operations: [],
        deletionsSuppressed: false,
      ),
      report: ExecutionReport(
        completed: [],
        skipped: [],
        failed: {},
      ),
      baselineConfirmed: true,
    );
  }
}

final class _FakeLocalObjectStore implements LocalObjectStore {
  final Map<String, String> existingFiles = {};
  final List<String> deletedFiles = [];
  final List<String> savedTombstones = [];

  @override
  Future<void> delete(
    SyncPath path, {
    required LocalCondition condition,
    SyncEntry? tombstone,
    String? operationId,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final currentSha = existingFiles[path.value];
    if (condition is LocalMatchSha256 && currentSha != condition.sha256) {
      throw const NeedsRescan('hash mismatch');
    }
    existingFiles.remove(path.value);
    deletedFiles.add(path.value);
    if (tombstone != null) {
      savedTombstones.add(path.value);
    }
  }

  @override
  Future<void> saveTombstone(
    SyncPath path,
    SyncEntry tombstone, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    savedTombstones.add(path.value);
  }

  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) async =>
      Stream<List<int>>.value(const [1, 2, 3]);

  @override
  Future<StagedObject> stage(
    SyncPath path,
    Stream<List<int>> content, {
    required String expectedSha256,
    CancellationToken token = const NeverCancelled(),
  }) =>
      throw UnimplementedError();

  @override
  Future<Stream<List<int>>> openStaged(
    StagedObject staged, {
    CancellationToken token = const NeverCancelled(),
  }) =>
      throw UnimplementedError();

  @override
  Future<bool> verifyStaged(
    StagedObject staged, {
    required String expectedSha256,
    required int expectedLength,
    CancellationToken token = const NeverCancelled(),
  }) =>
      throw UnimplementedError();

  @override
  Future<void> commitStaged(
    SyncPath path,
    StagedObject staged, {
    required SyncEntry entry,
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) =>
      throw UnimplementedError();

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    CancellationToken token = const NeverCancelled(),
  }) =>
      throw UnimplementedError();
}
