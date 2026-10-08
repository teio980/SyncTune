import 'package:synctune_sync_core/synctune_sync_core.dart';
import 'package:test/test.dart';

final now = DateTime.utc(2026, 1, 1);
String hash(String value) => value.padRight(64, value[0]);
SyncEntry file(String id, SyncPath path, String value,
        {int revision = 0,
        FavoriteStamp favorite =
            const FavoriteStamp(value: false, lamport: 0, deviceId: '')}) =>
    SyncEntry.file(
        id: id,
        path: path,
        size: 1,
        modifiedAtUtc: now,
        sha256: hash(value),
        revision: revision,
        favorite: favorite);
SyncSnapshot local(Iterable<SyncEntry> entries,
        {ScanCompleteness completeness = ScanCompleteness.complete}) =>
    SyncSnapshot(
        deviceId: 'local',
        capturedAtUtc: now,
        entries: entries,
        completeness: completeness,
        generation: 'g1');
RemoteSnapshot remote(Map<SyncPath, RemoteObject> entries,
        {ScanCompleteness completeness = ScanCompleteness.complete,
        String generation = 'g1'}) =>
    RemoteSnapshot(
        entries: entries,
        completeness: completeness,
        generation: generation,
        capturedAtUtc: now);

void main() {
  test('upload telemetry follows real planning and final confirmation',
      () async {
    const root = SyncRoot('root', generation: 'g1');
    final path = SyncPath.parse('song.mp3');
    final entry = file('song', path, 'a');
    final baseline = FakeBaseline();
    final repository = FakeRemote();
    final token = _ProgressToken();
    final result = await const SyncCoordinator().run(root,
        planId: 'live-progress',
        localSnapshots: SnapshotSequenceLocal([
          local([entry]),
          local([entry])
        ]),
        remoteSnapshots: SnapshotSequenceRemote([
          remote({}),
          remote({path: RemoteObject(entry: entry, etag: '"e1"')})
        ]),
        baseline: baseline,
        local: FakeLocal(),
        remote: repository,
        journal: FakeJournal(),
        token: token);
    result.requireConfirmed();
    expect(repository.putCalls, 1);
    expect(baseline.saved!.entries[path]!.sha256, entry.sha256);
    expect(token.events.map((event) => event.stage), [
      'Recovering previous sync',
      'Scanning local music',
      'Scanning cloud music',
      'Planning sync',
      'Uploading',
      'Updating favorites',
      'File operations complete',
      'Verifying local music',
      'Verifying cloud music',
      'Saving sync result'
    ]);
    final upload =
        token.events.firstWhere((event) => event.stage == 'Uploading');
    expect(upload.path, 'song.mp3');
    expect(upload.totalItems, 2);
  });

  const root = SyncRoot('root', generation: 'g1');
  test('path safety rejects ADS, aliases and wildcards but accepts COM1song',
      () {
    expect(() => SyncPath.parse('AUX.mp3'), throwsFormatException);
    expect(() => SyncPath.parse('track:stream'), throwsFormatException);
    expect(() => SyncPath.parse('track?.mp3'), throwsFormatException);
    expect(SyncPath.parse('COM1song.mp3').value, 'COM1song.mp3');
  });
  test('favorite merge is greatest Lamport then device id', () {
    const a = FavoriteStamp(value: true, lamport: 3, deviceId: 'z');
    const b = FavoriteStamp(value: false, lamport: 4, deviceId: 'a');
    const c = FavoriteStamp(value: true, lamport: 4, deviceId: 'b');
    expect(a.merge(b), b);
    expect(b.merge(c), c);
    expect(c.merge(c), c);
  });
  test('delete priority: delete versus edit preserves the tombstone', () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final tombstone = SyncEntry.tombstone(
        id: 'song', path: p, modifiedAtUtc: now, revision: 2);
    final edit = file('song', p, 'b', revision: 1);
    final one = const ThreeWayMerger()
        .merge(base: base, local: tombstone, remote: edit);
    final two = const ThreeWayMerger()
        .merge(base: base, local: edit, remote: tombstone);
    expect(one.entry!.isDeleted, isTrue);
    expect(two.entry!.isDeleted, isTrue);
  });
  test('delete priority: tombstone wins without baseline and with different ids', () {
    final p = SyncPath.parse('music/song.mp3');
    final tombstone = SyncEntry.tombstone(
        id: 'local-id', path: p, modifiedAtUtc: now, revision: 1);
    final remoteEdit = file('remote-id', p, 'b', revision: 1);
    final merged = const ThreeWayMerger()
        .merge(base: null, local: tombstone, remote: remoteEdit);
    expect(merged.entry!.isDeleted, isTrue);
    expect(merged.conflict, isFalse);
  });
  test('delete versus edit still merges the independent favorite stamp', () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final tombstone = SyncEntry.tombstone(
      id: 'song',
      path: p,
      modifiedAtUtc: now,
      revision: 2,
      favorite: const FavoriteStamp(value: true, lamport: 2, deviceId: 'phone'),
    );
    final edit = file(
      'song',
      p,
      'b',
      revision: 1,
      favorite:
          const FavoriteStamp(value: false, lamport: 1, deviceId: 'server'),
    );
    final merged = const ThreeWayMerger().merge(
      base: base,
      local: tombstone,
      remote: edit,
    );
    expect(merged.entry!.isDeleted, isTrue);
    expect(merged.entry!.favorite, tombstone.favorite);
  });
  test('same initial content with different identities does not duplicate', () {
    final p = SyncPath.parse('music/song.mp3');
    final localEntry = file('local-id', p, 'a');
    final remoteEntry = file('remote-id', p, 'a');
    final merged = const ThreeWayMerger().merge(
      base: null,
      local: localEntry,
      remote: remoteEntry,
    );
    expect(merged.conflict, isFalse);
    expect(merged.entry!.id, 'local-id');

    final plan = const SyncPlanner().plan(
      planId: 'same-initial-content',
      root: root,
      baseline: null,
      local: local([localEntry]),
      remote: remote({
        p: RemoteObject(
          entry: remoteEntry,
          etag: '"content"',
          metadataEtag: '"metadata"',
        ),
      }),
    );
    expect(plan.conflicts, isEmpty);
    expect(plan.operations, isEmpty);
  });
  test('same-id concurrent edits choose a deterministic collision-safe path',
      () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final localEdit = file('song', p, 'b', revision: 1);
    final remoteEdit = file('song', p, 'c', revision: 99);
    final one = const ThreeWayMerger()
        .merge(base: base, local: localEdit, remote: remoteEdit);
    final two = const ThreeWayMerger()
        .merge(base: base, local: remoteEdit, remote: localEdit);
    expect(one.conflict, isTrue);
    expect(two.conflict, isTrue);
    expect(one.entry!.sha256, two.entry!.sha256);
    expect(one.other!.sha256, two.other!.sha256);
    expect(one.preservePath, two.preservePath);
    expect(one.preservePath!.value, contains('sync-conflict-'));

    final plan = const SyncPlanner().plan(
      planId: 'conflict-contract',
      root: root,
      baseline: local([base]),
      local: local([localEdit]),
      remote: remote({
        p: RemoteObject(
            entry: remoteEdit, etag: '"content"', metadataEtag: '"metadata"'),
      }),
    );
    final operation = plan.operations.single;
    expect(operation.kind, SyncOperationKind.conflict);
    expect(operation.sourceIsLocal, isA<bool>());
    expect(operation.other!.path, operation.preservePath);
    expect(operation.other!.id, isNot(operation.source!.id));
    final restored = SyncPlanCodec.decode(SyncPlanCodec.encode(plan));
    expect(restored.operations.single.other!.path, operation.preservePath);
    expect(restored.operations.single.sourceIsLocal, operation.sourceIsLocal);
  });
  test('partial scans suppress destructive operations', () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final tombstone = SyncEntry.tombstone(
        id: 'song', path: p, modifiedAtUtc: now, revision: 1);
    final plan = const SyncPlanner().plan(
        planId: 'run',
        root: root,
        baseline: local([base]),
        local: local([tombstone], completeness: ScanCompleteness.partial),
        remote: remote({p: RemoteObject(entry: base, etag: '"e1"')}));
    expect(
        plan.operations.where((x) => x.kind == SyncOperationKind.deleteRemote),
        isEmpty);
    expect(plan.deletionsSuppressed, isTrue);
  });
  test(
      'create requires If-None-Match and changed content changes operation identity',
      () {
    final p = SyncPath.parse('new/song.mp3');
    final first = const SyncPlanner().plan(
        planId: 'run-a',
        root: root,
        baseline: local([]),
        local: local([file('song', p, 'a')]),
        remote: remote({}));
    final second = const SyncPlanner().plan(
        planId: 'run-b',
        root: root,
        baseline: local([]),
        local: local([file('song', p, 'b')]),
        remote: remote({}));
    final firstContent = first.operations
        .firstWhere((x) => x.kind == SyncOperationKind.putLocalToRemote);
    final secondContent = second.operations
        .firstWhere((x) => x.kind == SyncOperationKind.putLocalToRemote);
    expect(firstContent.condition, isA<CreateOnly>());
    expect(firstContent.id, isNot(secondContent.id));
  });
  test('missing content ETag does not create an unconditional write', () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final changed = file('song', p, 'b', revision: 1);
    final plan = const SyncPlanner().plan(
        planId: 'etag',
        root: root,
        baseline: local([base]),
        local: local([changed]),
        remote: remote({p: RemoteObject(entry: base, etag: null)}));
    expect(plan.operations.single.condition, isNull);
  });
  test('content uploads carry an independent metadata CAS condition', () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final changed = file('song', p, 'b', revision: 1);
    final plan = const SyncPlanner().plan(
      planId: 'separate-conditions',
      root: root,
      baseline: local([base]),
      local: local([changed]),
      remote: remote({
        p: RemoteObject(
          entry: base,
          etag: '"content-1"',
          metadataEtag: '"entry-1"',
          favoriteEtag: '"favorite-1"',
        ),
      }),
    );
    final operation = plan.operations.single;
    expect(operation.kind, SyncOperationKind.putLocalToRemote);
    expect((operation.condition! as MatchEtag).etag, '"content-1"');
    expect(
      (operation.metadataCondition! as MatchEtag).etag,
      '"entry-1"',
    );
  });
  test('favorite updates use the favorite object ETag', () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final changedFavorite = file(
      'song',
      p,
      'a',
      favorite: const FavoriteStamp(
        value: true,
        lamport: 1,
        deviceId: 'local-device',
      ),
    );
    final plan = const SyncPlanner().plan(
      planId: 'favorite-condition',
      root: root,
      baseline: local([base]),
      local: local([changedFavorite]),
      remote: remote({
        p: RemoteObject(
          entry: base,
          etag: '"content-1"',
          metadataEtag: '"entry-1"',
          favoriteEtag: '"favorite-1"',
        ),
      }),
    );
    final operation = plan.operations.single;
    expect(operation.kind, SyncOperationKind.updateFavoriteToRemote);
    expect((operation.condition! as MatchEtag).etag, '"favorite-1"');
  });
  test('remote tombstone takes priority over local edit and deletes local', () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final edited = file('song', p, 'b', revision: 1);
    final tombstone = SyncEntry.tombstone(
      id: 'song',
      path: p,
      modifiedAtUtc: now,
      revision: 1,
    );
    final plan = const SyncPlanner().plan(
      planId: 'remote-tombstone-priority',
      root: root,
      baseline: local([base]),
      local: local([edited]),
      remote: remote({
        p: RemoteObject(
          entry: tombstone,
          etag: null,
          metadataEtag: '"tombstone-metadata"',
        ),
      }),
    );
    final operation = plan.operations.single;
    expect(operation.kind, SyncOperationKind.deleteLocal);
    expect(operation.source!.isDeleted, isTrue);
    expect(operation.source!.id, tombstone.id);
  });
  test('tombstoneRemote is planned and executed when remote content is absent', () async {
    final p = SyncPath.parse('music/song.mp3');
    final tombstone = SyncEntry.tombstone(
        id: 'song', path: p, modifiedAtUtc: now, revision: 1);
    final plan = const SyncPlanner().plan(
      planId: 'plan-tombstone-remote',
      root: root,
      baseline: null,
      local: local([tombstone]),
      remote: remote({}),
    );
    final operation = plan.operations.single;
    expect(operation.kind, SyncOperationKind.tombstoneRemote);

    final localStore = FakeLocal();
    final remoteRepo = FakeRemote();
    final result = await const SyncCoordinator().run(
      root,
      planId: 'exec-tombstone-remote',
      localSnapshots: SnapshotSequenceLocal([
        local([tombstone]),
        local([tombstone]),
      ]),
      remoteSnapshots: SnapshotSequenceRemote([
        remote({}),
        remote({p: RemoteObject(entry: tombstone, etag: null, metadataEtag: '"m1"')}),
      ]),
      baseline: FakeBaseline(),
      local: localStore,
      remote: remoteRepo,
      journal: FakeJournal(),
    );
    result.requireConfirmed();
    expect(remoteRepo.putTombstoneCalls, 1);
  });
  test('tombstoneLocal is planned and executed when local file is absent', () async {
    final p = SyncPath.parse('music/song.mp3');
    final tombstone = SyncEntry.tombstone(
        id: 'song', path: p, modifiedAtUtc: now, revision: 1);
    final plan = const SyncPlanner().plan(
      planId: 'plan-tombstone-local',
      root: root,
      baseline: null,
      local: local([]),
      remote: remote({
        p: RemoteObject(entry: tombstone, etag: null, metadataEtag: '"m1"')
      }),
    );
    final operation = plan.operations.single;
    expect(operation.kind, SyncOperationKind.tombstoneLocal);

    final localStore = FakeLocal();
    final remoteRepo = FakeRemote();
    final result = await const SyncCoordinator().run(
      root,
      planId: 'exec-tombstone-local',
      localSnapshots: SnapshotSequenceLocal([
        local([]),
        local([tombstone]),
      ]),
      remoteSnapshots: SnapshotSequenceRemote([
        remote({p: RemoteObject(entry: tombstone, etag: null, metadataEtag: '"m1"')}),
        remote({p: RemoteObject(entry: tombstone, etag: null, metadataEtag: '"m1"')}),
      ]),
      baseline: FakeBaseline(),
      local: localStore,
      remote: remoteRepo,
      journal: FakeJournal(),
    );
    result.requireConfirmed();
    expect(localStore.saveTombstoneCalls, 1);
  });
  test('missing favorite object uses create-only CAS', () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final favorite = file(
      'song',
      p,
      'a',
      favorite: const FavoriteStamp(
        value: true,
        lamport: 1,
        deviceId: 'local-device',
      ),
    );
    final plan = const SyncPlanner().plan(
      planId: 'create-favorite',
      root: root,
      baseline: local([base]),
      local: local([favorite]),
      remote: remote({
        p: RemoteObject(
          entry: base,
          etag: '"content-1"',
          metadataEtag: '"entry-1"',
          favoriteEtag: null,
        ),
      }),
    );
    final operation = plan.operations.single;
    expect(operation.kind, SyncOperationKind.updateFavoriteToRemote);
    expect(operation.condition, isA<CreateOnly>());
  });
  test('remote tombstone propagates to local', () {
    final p = SyncPath.parse('music/song.mp3');
    final base = file('song', p, 'a');
    final tombstone = SyncEntry.tombstone(
        id: 'song', path: p, modifiedAtUtc: now, revision: 1);
    final plan = const SyncPlanner().plan(
        planId: 'delete',
        root: root,
        baseline: local([base]),
        local: local([base]),
        remote: remote({p: RemoteObject(entry: tombstone, etag: '"e2"')}));
    expect(plan.operations.single.kind, SyncOperationKind.deleteLocal);
  });
  test('complete absence becomes a tombstone deletion', () {
    final path = SyncPath.parse('music/song.mp3');
    final base = file('song', path, 'a');
    final plan = const SyncPlanner().plan(
      planId: 'delete-local',
      root: root,
      baseline: local([base]),
      local: local([]),
      remote: remote({path: RemoteObject(entry: base, etag: '"e1"')}),
    );
    expect(plan.operations.single.kind, SyncOperationKind.deleteRemote);
    expect(plan.operations.single.condition, isA<MatchEtag>());
  });
  test('deleteRemote persists the tombstone locally and confirms post-scan baseline',
      () async {
    final path = SyncPath.parse('music/song.mp3');
    final base = file('song', path, 'a');
    final tombstone = SyncEntry.tombstone(
      id: 'song',
      path: path,
      modifiedAtUtc: now,
      revision: 2,
    );
    final plan = const SyncPlanner().plan(
      planId: 'delete-remote-plan',
      root: root,
      baseline: local([base]),
      local: local([]),
      remote: remote({path: RemoteObject(entry: base, etag: '"e1"')}),
    );
    expect(plan.operations.single.kind, SyncOperationKind.deleteRemote);

    final localStore = FakeLocal();
    final remoteRepo = FakeRemote();
    final result = await const SyncCoordinator().run(
      root,
      planId: 'exec-delete-remote',
      localSnapshots: SnapshotSequenceLocal([
        local([]),
        local([tombstone]),
      ]),
      remoteSnapshots: SnapshotSequenceRemote([
        remote({
          path: RemoteObject(
              entry: base, etag: '"e1"', metadataEtag: '"m1"')
        }),
        remote({
          path: RemoteObject(entry: tombstone, etag: null, metadataEtag: '"m1"')
        }),
      ]),
      baseline: FakeBaseline(local([base])),
      local: localStore,
      remote: remoteRepo,
      journal: FakeJournal(),
    );
    result.requireConfirmed();
    expect(localStore.saveTombstoneCalls, 1);
    expect(localStore.savedLocalTombstone?.isDeleted, isTrue);
  });
  test('local delete journals recovery intent before touching the provider',
      () async {
    final path = SyncPath.parse('music/song.mp3');
    final base = file('song', path, 'a');
    final tombstone = SyncEntry.tombstone(
      id: 'song',
      path: path,
      modifiedAtUtc: now,
      revision: 1,
    );
    final plan = const SyncPlanner().plan(
      planId: 'delete-local-execution',
      root: root,
      baseline: local([base]),
      local: local([base]),
      remote: remote({path: RemoteObject(entry: tombstone, etag: '"e2"')}),
    );
    final journal = FakeJournal();
    final localStore = FakeLocal(currentSha256: base.sha256);
    await const SyncExecutor().execute(
      plan,
      local: localStore,
      remote: FakeRemote(),
      journal: journal,
    );

    expect(localStore.deleteCalls, 1);
    expect(journal.records.map((record) => record.state), [
      JournalState.staged,
      JournalState.committed,
    ]);
    expect(journal.records.first.condition, 'local-sha256:${base.sha256}');
  });
  test('local recovery drift supersedes the stale plan and replans', () async {
    const stale = SyncPlan(
      planId: 'stale-plan',
      generation: 'g1',
      operations: <SyncOperation>[],
      deletionsSuppressed: false,
    );
    final localStore = FakeLocal(
      recoveryError: const NeedsRescan('local precondition changed'),
    );
    final result = await const SyncCoordinator().run(
      root,
      planId: 'fresh-plan',
      localSnapshots: SnapshotSequenceLocal([local([]), local([])]),
      remoteSnapshots: SnapshotSequenceRemote([remote({}), remote({})]),
      baseline: FakeBaseline(),
      local: localStore,
      remote: FakeRemote(),
      journal: FakeJournal(),
      plans: FakePlanStore(stale),
    );

    expect(result.plan.planId, 'fresh-plan');
    expect(localStore.recoveryCalls, 1);
  });
  test('lost authorization pauses planning and weak ETags are rejected', () {
    final path = SyncPath.parse('music/song.mp3');
    final base = file('song', path, 'a');
    expect(
      () => const SyncPlanner().plan(
        planId: 'unauthorized',
        root: root,
        baseline: local([base]),
        local: local([base], completeness: ScanCompleteness.unauthorized),
        remote: remote({path: RemoteObject(entry: base, etag: '"e1"')}),
      ),
      throwsA(isA<NeedsRescan>()),
    );
    expect(() => MatchEtag('W/"weak"'), throwsFormatException);
    expect(() => MatchEtag('unquoted'), throwsFormatException);
    expect(MatchEtag('""').etag, '""');
    expect(() => MatchEtag('"has space"'), throwsFormatException);
  });
  test('generation change pauses planning', () {
    final path = SyncPath.parse('music/song.mp3');
    final entry = file('song', path, 'a');
    expect(
      () => const SyncPlanner().plan(
        planId: 'generation',
        root: root,
        baseline: local([entry]),
        local: local([entry]),
        remote: remote({}, generation: 'g2'),
      ),
      throwsA(isA<NeedsRescan>()),
    );
  });
  test('remote namespace changes never reuse the old deletion baseline', () {
    final path = SyncPath.parse('music/song.mp3');
    final entry = file('song', path, 'a');
    final otherNamespace = const SyncRoot(
      'root',
      generation: 'g1',
      remoteNamespace: 'server-b/music',
    );
    final plan = const SyncPlanner().plan(
      planId: 'remote-switch',
      root: otherNamespace,
      baseline: null,
      local: local([entry]),
      remote: remote({}, generation: 'g1'),
    );
    expect(
      plan.operations
          .where((item) => item.kind == SyncOperationKind.deleteLocal),
      isEmpty,
    );
    expect(
      plan.operations.any(
        (item) => item.kind == SyncOperationKind.putLocalToRemote,
      ),
      isTrue,
    );
  });
  test('412 stops stale plan before next operation', () async {
    final one = SyncPath.parse('one.mp3');
    final two = SyncPath.parse('two.mp3');
    final plan = const SyncPlanner().plan(
      planId: '412',
      root: root,
      baseline: local([]),
      local: local([file('one', one, 'a'), file('two', two, 'b')]),
      remote: remote({}),
    );
    final remoteStore = FakeRemote(preconditionFailure: true);
    await expectLater(
      const SyncExecutor().execute(
        plan,
        local: FakeLocal(),
        remote: remoteStore,
        journal: FakeJournal(),
      ),
      throwsA(isA<NeedsRescan>()),
    );
    expect(remoteStore.putCalls, 1);
  });
  test('staging hash mismatch never reaches remote commit', () async {
    final path = SyncPath.parse('one.mp3');
    final plan = const SyncPlanner().plan(
      planId: 'hash',
      root: root,
      baseline: local([]),
      local: local([file('one', path, 'a')]),
      remote: remote({}),
    );
    final remoteStore = FakeRemote();
    await expectLater(
      const SyncExecutor().execute(
        plan,
        local: FakeLocal(reportWrongHash: true),
        remote: remoteStore,
        journal: FakeJournal(),
      ),
      throwsA(isA<NeedsRescan>()),
    );
    expect(remoteStore.putCalls, 0);
  });
  test('commit followed by journal failure requires reconciliation', () async {
    final path = SyncPath.parse('one.mp3');
    final plan = const SyncPlanner().plan(
      planId: 'journal-gap',
      root: root,
      baseline: local([]),
      local: local([file('one', path, 'a')]),
      remote: remote({}),
    );
    final remoteStore = FakeRemote();
    await expectLater(
      const SyncExecutor().execute(
        plan,
        local: FakeLocal(),
        remote: remoteStore,
        journal: FailingCommitJournal(),
      ),
      throwsA(isA<NeedsRescan>()),
    );
    expect(remoteStore.putCalls, 1);
  });
  test('local commit/delete uses the scanned hash as a precondition', () async {
    final path = SyncPath.parse('one.mp3');
    final base = file('one', path, 'a');
    final tombstone = SyncEntry.tombstone(
        id: 'one', path: path, modifiedAtUtc: now, revision: 1);
    final plan = const SyncPlanner().plan(
      planId: 'local-precondition',
      root: root,
      baseline: local([base]),
      local: local([base]),
      remote: remote({path: RemoteObject(entry: tombstone, etag: '"e2"')}),
    );
    final current = file('one', path, 'c');
    await expectLater(
      const SyncExecutor().execute(
        plan,
        local: FakeLocal(currentSha256: current.sha256),
        remote: FakeRemote(),
        journal: FakeJournal(),
      ),
      throwsA(isA<NeedsRescan>()),
    );
  });
  test('upload preserves identity and next plan is empty', () async {
    final path = SyncPath.parse('one.mp3');
    final source = file('stable-one', path, 'a');
    final plan = const SyncPlanner().plan(
      planId: 'identity-upload',
      root: root,
      baseline: local([]),
      local: local([source]),
      remote: remote({}),
    );
    final remoteStore = FakeRemote();
    await const SyncExecutor().execute(
      plan,
      local: FakeLocal(),
      remote: remoteStore,
      journal: FakeJournal(),
    );
    expect(remoteStore.uploadedEntry, source);
    final next = const SyncPlanner().plan(
      planId: 'identity-upload-next',
      root: root,
      baseline: local([source]),
      local: local([source]),
      remote: remote({
        path: RemoteObject(
            entry: remoteStore.uploadedEntry!,
            etag: '"e1"',
            metadataEtag: '"m1"'),
      }),
    );
    expect(next.operations, isEmpty);
  });
  test('download preserves identity and next plan is empty', () async {
    final path = SyncPath.parse('one.mp3');
    final source = file('stable-one', path, 'a');
    final remoteStore = FakeRemote();
    final plan = const SyncPlanner().plan(
      planId: 'identity-download',
      root: root,
      baseline: local([]),
      local: local([]),
      remote: remote({
        path: RemoteObject(entry: source, etag: '"e1"', metadataEtag: '"m1"'),
      }),
    );
    final localStore = FakeLocal();
    await const SyncExecutor().execute(
      plan,
      local: localStore,
      remote: remoteStore,
      journal: FakeJournal(),
    );
    expect(localStore.committedEntry, source);
    final next = const SyncPlanner().plan(
      planId: 'identity-download-next',
      root: root,
      baseline: local([source]),
      local: local([source]),
      remote: remote({
        path: RemoteObject(entry: source, etag: '"e1"', metadataEtag: '"m1"'),
      }),
    );
    expect(next.operations, isEmpty);
  });
  test('staged journal record is reused after an interrupted run', () async {
    final path = SyncPath.parse('one.mp3');
    final source = file('stable-one', path, 'a');
    final plan = const SyncPlanner().plan(
      planId: 'staged-recovery',
      root: root,
      baseline: local([]),
      local: local([source]),
      remote: remote({}),
    );
    final operation = plan.operations
        .firstWhere((item) => item.kind == SyncOperationKind.putLocalToRemote);
    final journal = FakeJournal(seed: [
      JournalRecord(
        planId: plan.planId,
        generation: plan.generation,
        operationId: operation.id,
        path: path,
        state: JournalState.staged,
        atUtc: now,
        stagingKey: 'recovered-stage',
        sha256: source.sha256,
        length: 1,
      ),
    ]);
    final localStore = FakeLocal();
    final remoteStore = FakeRemote();
    await const SyncExecutor().execute(
      plan,
      local: localStore,
      remote: remoteStore,
      journal: journal,
    );
    expect(localStore.stageCalls, 0);
    expect(remoteStore.putCalls, 1);
    expect(journal.records.last.state, JournalState.committed);
  });
  test(
      'coordinator resumes a partially materialized conflict without repeating its copy',
      () async {
    final path = SyncPath.parse('one.mp3');
    final base = file('stable-one', path, 'a');
    final localEdit = file('stable-one', path, 'b', revision: 1);
    final remoteEdit = file('stable-one', path, 'c', revision: 1);
    final remoteView = remote({
      path: RemoteObject(
        entry: remoteEdit,
        etag: '"remote-content"',
        metadataEtag: '"remote-metadata"',
      ),
    });
    final initialLocal = local([localEdit]);
    final plan = const SyncPlanner().plan(
      planId: 'conflict-recovery',
      root: root,
      baseline: local([base]),
      local: initialLocal,
      remote: remoteView,
    );
    final operation = plan.operations.single;
    expect(operation.kind, SyncOperationKind.conflict);
    expect(operation.sourceIsLocal, isTrue);
    final secondary = operation.other!;
    final partialLocal = local([localEdit, secondary]);
    final journal = FakeJournal(seed: [
      JournalRecord(
        planId: plan.planId,
        generation: plan.generation,
        operationId: conflictCheckpointId(operation, 'stage-primary'),
        path: path,
        state: JournalState.staged,
        atUtc: now,
        stagingKey: 'primary-stage',
        sha256: operation.source!.sha256,
        length: operation.source!.size,
      ),
      JournalRecord(
        planId: plan.planId,
        generation: plan.generation,
        operationId: conflictCheckpointId(operation, 'stage-secondary'),
        path: operation.preservePath!,
        state: JournalState.staged,
        atUtc: now,
        stagingKey: 'secondary-stage',
        sha256: secondary.sha256,
        length: secondary.size,
      ),
    ]);
    final plans = FakePlanStore(plan);
    final localStore = FakeLocal();
    final remoteStore = FakeRemote();
    final result = await const SyncCoordinator().run(
      root,
      planId: 'should-not-replan',
      localSnapshots: SnapshotSequenceLocal([partialLocal, partialLocal]),
      remoteSnapshots: SnapshotSequenceRemote([remoteView, remoteView]),
      baseline: FakeBaseline(),
      local: localStore,
      remote: remoteStore,
      journal: journal,
      plans: plans,
    );

    expect(plans.superseded, 0);
    expect(result.plan.planId, plan.planId);
    expect(
      journal.records.any(
        (record) =>
            record.operationId ==
                conflictCheckpointId(operation, 'local-preserve') &&
            record.state == JournalState.committed,
      ),
      isTrue,
    );
    expect(localStore.commitCalls, 0);
    expect(remoteStore.putCalls, 2);
    expect(
      journal.records.where((record) => record.operationId == operation.id),
      hasLength(1),
    );
  });
  test('conflict recovery advances through remote commits without duplicates',
      () async {
    for (final phase in ['remote-primary', 'remote-preserve']) {
      final path = SyncPath.parse('one.mp3');
      final base = file('stable-one', path, 'a');
      final localEdit = file('stable-one', path, 'b', revision: 1);
      final remoteEdit = file('stable-one', path, 'c', revision: 1);
      final initialRemote = remote({
        path: RemoteObject(
          entry: remoteEdit,
          etag: '"remote-content"',
          metadataEtag: '"remote-metadata"',
        ),
      });
      final plan = const SyncPlanner().plan(
        planId: 'conflict-$phase',
        root: root,
        baseline: local([base]),
        local: local([localEdit]),
        remote: initialRemote,
      );
      final operation = plan.operations.single;
      final primary = operation.source!;
      final secondary = operation.other!;
      final preservePath = operation.preservePath!;
      final localView = local([localEdit, secondary]);
      final remoteEntries = <SyncPath, RemoteObject>{
        path: RemoteObject(
          entry: primary,
          etag: '"primary-content"',
          metadataEtag: '"primary-metadata"',
        ),
        if (phase == 'remote-preserve')
          preservePath: RemoteObject(
            entry: secondary,
            etag: '"secondary-content"',
            metadataEtag: '"secondary-metadata"',
          ),
      };
      final remoteView = remote(remoteEntries);
      final journal = FakeJournal(seed: [
        JournalRecord(
          planId: plan.planId,
          generation: plan.generation,
          operationId: conflictCheckpointId(operation, 'stage-primary'),
          path: path,
          state: JournalState.staged,
          atUtc: now,
          stagingKey: 'primary-stage',
          sha256: primary.sha256,
          length: primary.size,
        ),
        JournalRecord(
          planId: plan.planId,
          generation: plan.generation,
          operationId: conflictCheckpointId(operation, 'stage-secondary'),
          path: preservePath,
          state: JournalState.staged,
          atUtc: now,
          stagingKey: 'secondary-stage',
          sha256: secondary.sha256,
          length: secondary.size,
        ),
        JournalRecord(
          planId: plan.planId,
          generation: plan.generation,
          operationId: conflictCheckpointId(operation, 'local-preserve'),
          path: preservePath,
          state: JournalState.committed,
          atUtc: now,
        ),
        if (phase == 'remote-preserve')
          JournalRecord(
            planId: plan.planId,
            generation: plan.generation,
            operationId: conflictCheckpointId(operation, 'remote-primary'),
            path: path,
            state: JournalState.committed,
            atUtc: now,
          ),
      ]);
      final plans = FakePlanStore(plan);
      final localStore = FakeLocal();
      final remoteStore = FakeRemote();
      final result = await const SyncCoordinator().run(
        root,
        planId: 'should-not-replan-$phase',
        localSnapshots: SnapshotSequenceLocal([localView, localView]),
        remoteSnapshots: SnapshotSequenceRemote([remoteView, remoteView]),
        baseline: FakeBaseline(),
        local: localStore,
        remote: remoteStore,
        journal: journal,
        plans: plans,
      );

      expect(plans.superseded, 0, reason: phase);
      expect(result.plan.planId, plan.planId, reason: phase);
      expect(localStore.commitCalls, 0, reason: phase);
      expect(
        remoteStore.putCalls,
        phase == 'remote-primary' ? 1 : 0,
        reason: phase,
      );
      expect(
        journal.records.where((record) => record.operationId == operation.id),
        hasLength(1),
        reason: phase,
      );
    }
  });
  test('conflict recovery confirms both versions after the local replacement',
      () async {
    final path = SyncPath.parse('one.mp3');
    final base = file('stable-one', path, 'a');
    final localEdit = file('stable-one', path, 'c', revision: 1);
    final remoteEdit = file('stable-one', path, 'b', revision: 1);
    final plan = const SyncPlanner().plan(
      planId: 'conflict-local-replacement-recovery',
      root: root,
      baseline: local([base]),
      local: local([localEdit]),
      remote: remote({
        path: RemoteObject(
          entry: remoteEdit,
          etag: '"remote-content"',
          metadataEtag: '"remote-metadata"',
        ),
      }),
    );
    final operation = plan.operations.single;
    expect(operation.sourceIsLocal, isFalse);
    final primary = operation.source!;
    final secondary = operation.other!;
    final preservePath = operation.preservePath!;
    final localView = local([primary, secondary]);
    final remoteView = remote({
      path: RemoteObject(
        entry: primary,
        etag: '"primary-content"',
        metadataEtag: '"primary-metadata"',
      ),
      preservePath: RemoteObject(
        entry: secondary,
        etag: '"secondary-content"',
        metadataEtag: '"secondary-metadata"',
      ),
    });
    final journal = FakeJournal(seed: [
      JournalRecord(
        planId: plan.planId,
        generation: plan.generation,
        operationId: conflictCheckpointId(operation, 'stage-primary'),
        path: path,
        state: JournalState.staged,
        atUtc: now,
        stagingKey: 'primary-stage',
        sha256: primary.sha256,
        length: primary.size,
      ),
      JournalRecord(
        planId: plan.planId,
        generation: plan.generation,
        operationId: conflictCheckpointId(operation, 'stage-secondary'),
        path: preservePath,
        state: JournalState.staged,
        atUtc: now,
        stagingKey: 'secondary-stage',
        sha256: secondary.sha256,
        length: secondary.size,
      ),
      for (final step in ['local-preserve', 'remote-preserve'])
        JournalRecord(
          planId: plan.planId,
          generation: plan.generation,
          operationId: conflictCheckpointId(operation, step),
          path: preservePath,
          state: JournalState.committed,
          atUtc: now,
        ),
    ]);
    final plans = FakePlanStore(plan);
    final result = await const SyncCoordinator().run(
      root,
      planId: 'should-not-replan-local-replacement',
      localSnapshots: SnapshotSequenceLocal([localView, localView]),
      remoteSnapshots: SnapshotSequenceRemote([remoteView, remoteView]),
      baseline: FakeBaseline(),
      local: FakeLocal(),
      remote: FakeRemote(),
      journal: journal,
      plans: plans,
    );

    expect(plans.superseded, 0);
    expect(result.plan.planId, plan.planId);
    expect(result.baselineConfirmed, isTrue);
    expect(result.requireConfirmed, returnsNormally);
    expect(
      journal.records.any(
        (record) =>
            record.operationId ==
                conflictCheckpointId(operation, 'local-primary') &&
            record.state == JournalState.committed,
      ),
      isTrue,
    );
  });
  test(
      'preserve-both conflict applies the merged favorite to the local primary',
      () async {
    final path = SyncPath.parse('one.mp3');
    const localFavorite =
        FavoriteStamp(value: true, lamport: 1, deviceId: 'phone');
    const remoteFavorite =
        FavoriteStamp(value: false, lamport: 2, deviceId: 'server');
    final base = file('stable-one', path, 'a');
    final localEdit = file(
      'stable-one',
      path,
      'b',
      revision: 1,
      favorite: localFavorite,
    );
    final remoteEdit = file(
      'stable-one',
      path,
      'c',
      revision: 1,
      favorite: remoteFavorite,
    );
    final initialLocal = local([localEdit]);
    final initialRemote = remote({
      path: RemoteObject(
        entry: remoteEdit,
        etag: '"remote-content"',
        metadataEtag: '"remote-metadata"',
      ),
    });
    final plan = const SyncPlanner().plan(
      planId: 'conflict-favorite',
      root: root,
      baseline: local([base]),
      local: initialLocal,
      remote: initialRemote,
    );
    final operation = plan.operations.single;
    final primary = operation.source!;
    final secondary = operation.other!;
    expect(operation.sourceIsLocal, isTrue);
    expect(primary.favorite, remoteFavorite);
    final afterLocal = local([primary, secondary]);
    final preservePath = operation.preservePath!;
    final afterRemote = remote({
      path: RemoteObject(
        entry: primary,
        etag: '"primary-content"',
        metadataEtag: '"primary-metadata"',
      ),
      preservePath: RemoteObject(
        entry: secondary,
        etag: '"secondary-content"',
        metadataEtag: '"secondary-metadata"',
      ),
    });
    final localStore = FakeLocal();
    final result = await const SyncCoordinator().run(
      root,
      planId: plan.planId,
      localSnapshots: SnapshotSequenceLocal([initialLocal, afterLocal]),
      remoteSnapshots: SnapshotSequenceRemote([initialRemote, afterRemote]),
      baseline: FakeBaseline(),
      local: localStore,
      remote: FakeRemote(),
      journal: FakeJournal(),
    );

    expect(result.baselineConfirmed, isTrue);
    expect(localStore.favoriteWrites, [remoteFavorite]);
  });
  test('corrupt recovered staging is rejected before remote commit', () async {
    final path = SyncPath.parse('one.mp3');
    final source = file('stable-one', path, 'a');
    final plan = const SyncPlanner().plan(
      planId: 'staged-corrupt',
      root: root,
      baseline: local([]),
      local: local([source]),
      remote: remote({}),
    );
    final operation = plan.operations
        .firstWhere((item) => item.kind == SyncOperationKind.putLocalToRemote);
    final journal = FakeJournal(seed: [
      JournalRecord(
        planId: plan.planId,
        generation: plan.generation,
        operationId: operation.id,
        path: path,
        state: JournalState.staged,
        atUtc: now,
        stagingKey: 'corrupt-stage',
        sha256: source.sha256,
        length: 1,
      ),
    ]);
    final remoteStore = FakeRemote();
    await expectLater(
      const SyncExecutor().execute(
        plan,
        local: FakeLocal(verifyStagedResult: false),
        remote: remoteStore,
        journal: journal,
      ),
      throwsA(isA<NeedsRescan>()),
    );
    expect(remoteStore.putCalls, 0);
  });
  test('coordinator confirms a matching post-scan baseline', () async {
    final path = SyncPath.parse('one.mp3');
    final source = file('stable-one', path, 'a');
    final localView = local([source]);
    final remoteView = remote({
      path: RemoteObject(entry: source, etag: '"e1"', metadataEtag: '"m1"'),
    });
    final baseline = FakeBaseline();
    final result = await const SyncCoordinator().run(
      root,
      planId: 'coordinator-baseline',
      localSnapshots: SnapshotSequenceLocal([localView, localView]),
      remoteSnapshots: SnapshotSequenceRemote([remoteView, remoteView]),
      baseline: baseline,
      local: FakeLocal(),
      remote: FakeRemote(),
      journal: FakeJournal(),
    );
    expect(result.baselineConfirmed, isTrue);
    expect(baseline.saved, localView);
    expect(result.requireConfirmed, returnsNormally);
  });
  test('runtime success requires a confirmed post-scan baseline', () {
    const plan = SyncPlan(
      planId: 'unconfirmed',
      generation: 'g1',
      operations: <SyncOperation>[],
      deletionsSuppressed: false,
    );
    const report = ExecutionReport(
      completed: <String>[],
      skipped: <String>[],
      failed: <String, Object>{},
    );
    expect(
      () => const SyncRunResult(
        plan: plan,
        report: report,
        baselineConfirmed: false,
      ).requireConfirmed(),
      throwsA(isA<NeedsRescan>()),
    );
  });
}

final class _ProgressToken implements CancellationToken, SyncProgressReporter {
  final events = <SyncProgress>[];
  @override
  SyncProgress? get progress => events.isEmpty ? null : events.last;
  @override
  bool get isCancelled => false;
  @override
  void throwIfCancelled() {}
  @override
  void reportProgress(SyncProgress progress) => events.add(progress);
}

final class SnapshotSequenceLocal implements LocalSnapshotProvider {
  SnapshotSequenceLocal(this.views);
  final List<SyncSnapshot> views;
  @override
  Future<SyncSnapshot> capture(SyncRoot root,
      {CancellationToken token = const NeverCancelled()}) async {
    return views.length > 1 ? views.removeAt(0) : views.single;
  }
}

final class SnapshotSequenceRemote implements RemoteSnapshotProvider {
  SnapshotSequenceRemote(this.views);
  final List<RemoteSnapshot> views;
  @override
  Future<RemoteSnapshot> capture(SyncRoot root,
      {CancellationToken token = const NeverCancelled()}) async {
    return views.length > 1 ? views.removeAt(0) : views.single;
  }
}

final class FakeBaseline implements BaselineStore {
  FakeBaseline([this.saved]);
  SyncSnapshot? saved;
  @override
  Future<SyncSnapshot?> load(SyncRoot root) async => saved;
  @override
  Future<void> saveConfirmed(SyncRoot root, SyncSnapshot snapshot,
      {required String planId}) async {
    saved = snapshot;
  }
}

final class FakeLocal implements LocalObjectStore, LocalPlanRecovery {
  FakeLocal(
      {this.reportWrongHash = false,
      this.currentSha256,
      this.verifyStagedResult = true,
      this.recoveryError});
  final bool reportWrongHash;
  final String? currentSha256;
  final bool verifyStagedResult;
  final Object? recoveryError;
  int recoveryCalls = 0;
  SyncEntry? committedEntry;
  int commitCalls = 0;
  final List<FavoriteStamp> favoriteWrites = [];
  int stageCalls = 0;
  int deleteCalls = 0;
  @override
  Future<void> recoverPendingPlan(
    SyncRoot root,
    SyncPlan plan, {
    required Iterable<JournalRecord> journal,
    CancellationToken token = const NeverCancelled(),
  }) async {
    recoveryCalls++;
    final error = recoveryError;
    if (error != null) throw error;
  }

  @override
  Future<Stream<List<int>>> read(SyncPath path,
          {CancellationToken token = const NeverCancelled()}) async =>
      Stream<List<int>>.value(const [1]);
  @override
  Future<StagedObject> stage(SyncPath path, Stream<List<int>> content,
          {required String expectedSha256,
          CancellationToken token = const NeverCancelled()}) async =>
      _stage(expectedSha256);
  StagedObject _stage(String expectedSha256) {
    stageCalls++;
    return StagedObject(
        key: 'stage',
        sha256: reportWrongHash ? ''.padRight(64, '0') : expectedSha256,
        length: 1);
  }

  @override
  Future<Stream<List<int>>> openStaged(StagedObject staged,
          {CancellationToken token = const NeverCancelled()}) async =>
      Stream<List<int>>.value(const [1]);
  @override
  Future<bool> verifyStaged(StagedObject staged,
          {required String expectedSha256,
          required int expectedLength,
          CancellationToken token = const NeverCancelled()}) async =>
      verifyStagedResult;
  @override
  Future<void> commitStaged(SyncPath path, StagedObject staged,
      {required SyncEntry entry,
      required LocalCondition condition,
      CancellationToken token = const NeverCancelled()}) async {
    commitCalls++;
    committedEntry = entry;
  }

  int saveTombstoneCalls = 0;
  SyncEntry? savedLocalTombstone;

  @override
  Future<void> saveTombstone(SyncPath path, SyncEntry tombstone,
      {CancellationToken token = const NeverCancelled()}) async {
    saveTombstoneCalls++;
    savedLocalTombstone = tombstone;
  }

  @override
  Future<void> delete(SyncPath path,
      {required LocalCondition condition,
      SyncEntry? tombstone,
      String? operationId,
      CancellationToken token = const NeverCancelled()}) async {
    deleteCalls++;
    savedLocalTombstone = tombstone;
    if (condition is LocalMatchSha256 && condition.sha256 != currentSha256) {
      throw NeedsRescan('local object changed before delete');
    }
  }

  @override
  Future<void> updateFavorite(SyncPath path, FavoriteStamp stamp,
      {CancellationToken token = const NeverCancelled()}) async {
    favoriteWrites.add(stamp);
  }
}

final class FakeRemote implements RemoteRepository {
  FakeRemote({this.preconditionFailure = false});
  final bool preconditionFailure;
  int putCalls = 0;
  int putTombstoneCalls = 0;
  SyncEntry? uploadedEntry;
  SyncEntry? savedRemoteTombstone;
  RemoteCondition? uploadedContentCondition;
  RemoteCondition? uploadedMetadataCondition;
  @override
  Future<Stream<List<int>>> read(SyncPath path,
          {CancellationToken token = const NeverCancelled()}) async =>
      Stream<List<int>>.value(const [1]);
  @override
  Future<String> put(SyncPath path, Stream<List<int>> content,
      {required SyncEntry entry,
      required RemoteCondition condition,
      required RemoteCondition metadataCondition,
      CancellationToken token = const NeverCancelled()}) async {
    putCalls++;
    uploadedEntry = entry;
    uploadedContentCondition = condition;
    uploadedMetadataCondition = metadataCondition;
    if (preconditionFailure) throw RemotePreconditionFailed(path);
    return 'e';
  }

  @override
  Future<void> putTombstone(SyncPath path,
      {required SyncEntry tombstone,
      required RemoteCondition metadataCondition,
      CancellationToken token = const NeverCancelled()}) async {
    putTombstoneCalls++;
    savedRemoteTombstone = tombstone;
    uploadedMetadataCondition = metadataCondition;
    if (preconditionFailure) throw RemotePreconditionFailed(path);
  }

  @override
  Future<void> delete(SyncPath path,
      {required MatchEtag condition,
      SyncEntry? tombstone,
      RemoteCondition? metadataCondition,
      CancellationToken token = const NeverCancelled()}) async {
    savedRemoteTombstone = tombstone;
  }
  @override
  Future<void> updateFavorite(SyncPath path, FavoriteStamp stamp,
      {required RemoteCondition condition,
      CancellationToken token = const NeverCancelled()}) async {}
}

final class FakeJournal implements JournalStore {
  FakeJournal({Iterable<JournalRecord> seed = const []}) : records = [...seed];
  final List<JournalRecord> records;
  @override
  Future<List<JournalRecord>> recordsFor(
          String planId, String generation) async =>
      records;
  @override
  Future<void> append(JournalRecord record) async => records.add(record);
}

final class FakePlanStore implements PlanStore {
  FakePlanStore(this.unfinished);
  final SyncPlan unfinished;
  int superseded = 0;

  @override
  Future<void> markPlanFinished(SyncRoot root, String planId) async {}

  @override
  Future<void> markPlanSuperseded(SyncRoot root, String planId) async {
    superseded++;
  }

  @override
  Future<SyncPlan?> loadUnfinishedPlan(SyncRoot root) async => unfinished;

  @override
  Future<void> savePlan(SyncRoot root, SyncPlan plan) async {}
}

final class FailingCommitJournal implements JournalStore {
  @override
  Future<List<JournalRecord>> recordsFor(
          String planId, String generation) async =>
      [];

  @override
  Future<void> append(JournalRecord record) async {
    if (record.state == JournalState.committed) {
      throw StateError('simulated journal outage');
    }
  }
}
