import 'planner.dart';
import 'ports.dart';
import 'model.dart';

final class ExecutionReport {
  const ExecutionReport(
      {required this.completed, required this.skipped, required this.failed});
  final List<String> completed;
  final List<String> skipped;
  final Map<String, Object> failed;
  bool get hasFailures => failed.isNotEmpty;
}

final class SyncExecutor {
  const SyncExecutor();
  Future<ExecutionReport> execute(SyncPlan plan,
      {required LocalObjectStore local,
      required RemoteRepository remote,
      required JournalStore journal,
      SyncClock clock = const SystemSyncClock(),
      CancellationToken token = const NeverCancelled()}) async {
    final records = await journal.recordsFor(plan.planId, plan.generation);
    final committed = <String>{
      for (final record in records)
        if (record.state == JournalState.committed) record.operationId,
    };
    // A failed append after staging must not erase the durable staged
    // evidence. Keep the most recent verified candidate independently of the
    // operation's later failed marker; the executor will re-check its bytes
    // and current preconditions before reusing it.
    final staged = <String, JournalRecord>{
      for (final record in records)
        if (record.state == JournalState.staged &&
            record.stagingKey != null &&
            record.sha256 != null &&
            record.length != null)
          record.operationId: record,
    };
    final checkpoints = <String, JournalRecord>{
      for (final record in records) record.operationId: record,
    };
    final done = <String>[];
    final skipped = <String>[];
    final failed = <String, Object>{};
    for (final op in plan.operations) {
      token.throwIfCancelled();
      reportSyncProgress(
          token,
          SyncProgress(
              stage: switch (op.kind) {
                SyncOperationKind.putLocalToRemote => 'Uploading',
                SyncOperationKind.putRemoteToLocal => 'Downloading',
                SyncOperationKind.deleteLocal => 'Deleting local file',
                SyncOperationKind.deleteRemote => 'Deleting cloud file',
                SyncOperationKind.conflict => 'Preserving conflicting files',
                _ => 'Updating favorites',
              },
              path: op.path.value,
              completedItems: done.length + skipped.length,
              itemLabel: 'Operations completed',
              totalItems: plan.operations.length,
              totalBytes: op.kind == SyncOperationKind.putLocalToRemote ||
                      op.kind == SyncOperationKind.putRemoteToLocal
                  ? op.source?.size
                  : null));
      if (committed.contains(op.id)) {
        skipped.add(op.id);
        continue;
      }
      try {
        await _one(plan, op, local, remote, journal, clock, token,
            staged[op.id], checkpoints);
        done.add(op.id);
      } on SyncCancelled catch (e) {
        await _fail(plan, op, journal, clock, e);
        throw NeedsRescan(e);
      } on RemotePreconditionFailed catch (e) {
        await _fail(plan, op, journal, clock, e);
        throw NeedsRescan(e);
      } on NeedsRescan catch (e) {
        await _fail(plan, op, journal, clock, e);
        rethrow;
      } catch (e) {
        await _fail(plan, op, journal, clock, e);
        // A mutation may have landed before an adapter surfaced an ordinary
        // transport/storage error. Continuing with later operations would
        // compound a partial run, so every failed substep requires a fresh
        // snapshot before execution can continue.
        throw NeedsRescan(e);
      }
    }
    reportSyncProgress(
        token,
        SyncProgress(
            stage: 'File operations complete',
            completedItems: done.length + skipped.length,
            itemLabel: 'Operations completed',
            totalItems: plan.operations.length));
    return ExecutionReport(
        completed: List.unmodifiable(done),
        skipped: List.unmodifiable(skipped),
        failed: Map.unmodifiable(failed));
  }

  Future<void> _one(
      SyncPlan plan,
      SyncOperation op,
      LocalObjectStore local,
      RemoteRepository remote,
      JournalStore journal,
      SyncClock clock,
      CancellationToken token,
      JournalRecord? recoveredStage,
      Map<String, JournalRecord> checkpoints) async {
    token.throwIfCancelled();
    switch (op.kind) {
      case SyncOperationKind.putLocalToRemote:
        {
          final source = op.source;
          final sourceHash = source?.sha256;
          final condition = op.condition;
          final metadataCondition = op.metadataCondition;
          if (source == null ||
              sourceHash == null ||
              condition == null ||
              metadataCondition == null) {
            throw NeedsRescan('missing strong content or metadata condition');
          }
          final staged = recoveredStage == null
              ? await local.stage(
                  op.path, await local.read(op.path, token: token),
                  expectedSha256: sourceHash, token: token)
              : StagedObject(
                  key: recoveredStage.stagingKey!,
                  sha256: recoveredStage.sha256!,
                  length: recoveredStage.length!);
          if (source.kind != SyncEntryKind.file ||
              staged.sha256 != sourceHash ||
              staged.length != source.size) {
            throw NeedsRescan('staging bytes do not match source metadata');
          }
          if (recoveredStage != null &&
              !await local.verifyStaged(staged,
                  expectedSha256: sourceHash,
                  expectedLength: source.size,
                  token: token)) {
            throw NeedsRescan('recovered staging bytes failed verification');
          }
          if (recoveredStage == null) {
            await journal.append(JournalRecord(
                planId: plan.planId,
                generation: plan.generation,
                operationId: op.id,
                path: op.path,
                state: JournalState.staged,
                atUtc: clock.nowUtc,
                stagingKey: staged.key,
                sha256: staged.sha256,
                length: staged.length,
                condition: condition.fingerprint,
                metadataCondition: metadataCondition.fingerprint));
          }
          await remote.put(
              op.path, await local.openStaged(staged, token: token),
              entry: source,
              condition: condition,
              metadataCondition: metadataCondition,
              token: token);
        }
      case SyncOperationKind.putRemoteToLocal:
        {
          final source = op.source;
          final sourceHash = source?.sha256;
          if (source == null || sourceHash == null) {
            throw NeedsRescan('missing remote hash');
          }
          final staged = recoveredStage == null
              ? await local.stage(
                  op.path, await remote.read(op.path, token: token),
                  expectedSha256: sourceHash, token: token)
              : StagedObject(
                  key: recoveredStage.stagingKey!,
                  sha256: recoveredStage.sha256!,
                  length: recoveredStage.length!);
          if (source.kind != SyncEntryKind.file ||
              staged.sha256 != sourceHash ||
              staged.length != source.size) {
            throw NeedsRescan('staging bytes do not match source metadata');
          }
          if (recoveredStage != null &&
              !await local.verifyStaged(staged,
                  expectedSha256: sourceHash,
                  expectedLength: source.size,
                  token: token)) {
            throw NeedsRescan('recovered staging bytes failed verification');
          }
          if (recoveredStage == null) {
            await journal.append(JournalRecord(
                planId: plan.planId,
                generation: plan.generation,
                operationId: op.id,
                path: op.path,
                state: JournalState.staged,
                atUtc: clock.nowUtc,
                stagingKey: staged.key,
                sha256: staged.sha256,
                length: staged.length,
                condition: op.localCondition?.fingerprint));
          }
          final localCondition = op.localCondition;
          if (localCondition == null) {
            throw NeedsRescan('missing local commit condition');
          }
          await local.commitStaged(op.path, staged,
              entry: source, condition: localCondition, token: token);
        }
      case SyncOperationKind.deleteRemote:
        if (op.condition is! MatchEtag ||
            op.source == null ||
            op.metadataCondition == null) {
          throw NeedsRescan('missing remote delete or tombstone condition');
        }
        // DELETE and tombstone PUT are two remote mutations. Persist an
        // intent before the first one so a restart can distinguish an
        // interrupted delete from an externally missing object.
        if (checkpoints[op.id]?.state != JournalState.staged) {
          final intent = JournalRecord(
            planId: plan.planId,
            generation: plan.generation,
            operationId: op.id,
            path: op.path,
            state: JournalState.staged,
            atUtc: clock.nowUtc,
            condition: op.condition!.fingerprint,
            metadataCondition: op.metadataCondition!.fingerprint,
          );
          await journal.append(intent);
          checkpoints[op.id] = intent;
          token.throwIfCancelled();
        }
        await remote.delete(op.path,
            condition: op.condition! as MatchEtag,
            tombstone: op.source,
            metadataCondition: op.metadataCondition,
            token: token);
      case SyncOperationKind.deleteLocal:
        final localCondition = op.localCondition;
        if (localCondition is! LocalMatchSha256) {
          throw NeedsRescan('missing local delete hash');
        }
        if (checkpoints[op.id]?.state != JournalState.staged) {
          final intent = JournalRecord(
            planId: plan.planId,
            generation: plan.generation,
            operationId: op.id,
            path: op.path,
            state: JournalState.staged,
            atUtc: clock.nowUtc,
            condition: localCondition.fingerprint,
          );
          await journal.append(intent);
          checkpoints[op.id] = intent;
          token.throwIfCancelled();
        }
        await local.delete(op.path,
            condition: localCondition, operationId: op.id, token: token);
      case SyncOperationKind.updateFavoriteToRemote:
        if (op.condition == null || op.source == null) {
          throw NeedsRescan('missing metadata ETag');
        }
        await remote.updateFavorite(op.path, op.source!.favorite,
            condition: op.condition!, token: token);
      case SyncOperationKind.updateFavoriteToLocal:
        if (op.source == null) {
          throw NeedsRescan('missing favorite source');
        }
        await local.updateFavorite(op.path, op.source!.favorite, token: token);
      case SyncOperationKind.conflict:
        await _materializeConflict(
          plan,
          op,
          local,
          remote,
          journal,
          clock,
          token,
          checkpoints,
        );
    }
    try {
      await journal.append(JournalRecord(
          planId: plan.planId,
          generation: plan.generation,
          operationId: op.id,
          path: op.path,
          state: JournalState.committed,
          atUtc: clock.nowUtc,
          condition: op.condition?.fingerprint,
          metadataCondition: op.metadataCondition?.fingerprint));
    } catch (error) {
      // The adapter may have committed successfully before the durable
      // journal write failed. Never retry this stale plan blindly.
      throw NeedsRescan(
          'commit completed but journal state is uncertain: $error');
    }
  }

  Future<void> _materializeConflict(
    SyncPlan plan,
    SyncOperation op,
    LocalObjectStore local,
    RemoteRepository remote,
    JournalStore journal,
    SyncClock clock,
    CancellationToken token,
    Map<String, JournalRecord> checkpoints,
  ) async {
    final primary = op.source;
    final secondary = op.other;
    final preservePath = op.preservePath;
    final sourceIsLocal = op.sourceIsLocal;
    if (primary == null ||
        secondary == null ||
        preservePath == null ||
        sourceIsLocal == null ||
        primary.kind != SyncEntryKind.file ||
        secondary.kind != SyncEntryKind.file ||
        primary.path != op.path ||
        secondary.path != preservePath ||
        primary.sha256 == null ||
        secondary.sha256 == null) {
      throw const NeedsRescan('preserve-both conflict metadata is incomplete');
    }

    void verifyStage(StagedObject staged, SyncEntry entry) {
      if (staged.sha256 != entry.sha256 || staged.length != entry.size) {
        throw const NeedsRescan('preserve-both staging bytes do not match');
      }
    }

    Future<StagedObject> stageConflictVersion(
      String step,
      SyncPath readPath,
      SyncEntry entry,
      Future<Stream<List<int>>> Function() content,
    ) async {
      final checkpointId = conflictCheckpointId(op, step);
      final recovered = checkpoints[checkpointId];
      if (recovered != null &&
          recovered.state == JournalState.staged &&
          recovered.stagingKey != null &&
          recovered.sha256 == entry.sha256 &&
          recovered.length == entry.size) {
        final staged = StagedObject(
          key: recovered.stagingKey!,
          sha256: recovered.sha256!,
          length: recovered.length!,
        );
        if (!await local.verifyStaged(
          staged,
          expectedSha256: entry.sha256!,
          expectedLength: entry.size,
          token: token,
        )) {
          throw const NeedsRescan(
            'recovered conflict staging bytes failed verification',
          );
        }
        return staged;
      }
      final staged = await local.stage(
        readPath,
        await content(),
        expectedSha256: entry.sha256!,
        token: token,
      );
      verifyStage(staged, entry);
      final record = JournalRecord(
        planId: plan.planId,
        generation: plan.generation,
        operationId: checkpointId,
        path: readPath,
        state: JournalState.staged,
        atUtc: clock.nowUtc,
        stagingKey: staged.key,
        sha256: staged.sha256,
        length: staged.length,
      );
      await journal.append(record);
      checkpoints[checkpointId] = record;
      return staged;
    }

    Future<void> commitStep(
        String step, SyncPath targetPath, Future<void> Function() commit,
        {StagedObject? staged,
        SyncEntry? entry,
        LocalCondition? condition}) async {
      final checkpointId = conflictCheckpointId(op, step);
      if (checkpoints[checkpointId]?.state == JournalState.committed) return;
      if (checkpoints[checkpointId]?.state != JournalState.staged) {
        final intent = JournalRecord(
          planId: plan.planId,
          generation: plan.generation,
          operationId: checkpointId,
          path: targetPath,
          state: JournalState.staged,
          atUtc: clock.nowUtc,
          stagingKey: staged?.key,
          sha256: staged?.sha256,
          length: staged?.length,
          condition: condition?.fingerprint,
        );
        await journal.append(intent);
        checkpoints[checkpointId] = intent;
        token.throwIfCancelled();
      }
      await commit();
      final record = JournalRecord(
        planId: plan.planId,
        generation: plan.generation,
        operationId: checkpointId,
        path: targetPath,
        state: JournalState.committed,
        atUtc: clock.nowUtc,
        stagingKey: staged?.key,
        sha256: staged?.sha256,
        length: staged?.length,
        condition: condition?.fingerprint,
      );
      await journal.append(record);
      checkpoints[checkpointId] = record;
    }

    if (sourceIsLocal) {
      final contentCondition = op.condition;
      final metadataCondition = op.metadataCondition;
      if (contentCondition == null || metadataCondition == null) {
        throw const NeedsRescan(
            'preserve-both primary remote conditions are unavailable');
      }
      // Verify both source streams before any mutation. In particular, the
      // primary must be staged too: a scan can become stale between planning
      // and execution, and sending local.read directly would pair a new byte
      // stream with the old descriptor.
      final primaryStage = await stageConflictVersion(
        'stage-primary',
        op.path,
        primary,
        () => local.read(op.path, token: token),
      );
      verifyStage(primaryStage, primary);
      final secondaryStage = await stageConflictVersion(
        'stage-secondary',
        op.path,
        secondary,
        () => remote.read(op.path, token: token),
      );
      verifyStage(secondaryStage, secondary);
      await commitStep(
        'local-preserve',
        preservePath,
        () => local.commitStaged(
          preservePath,
          secondaryStage,
          entry: secondary,
          condition: const LocalCreateOnly(),
          token: token,
        ),
        staged: secondaryStage,
        entry: secondary,
        condition: const LocalCreateOnly(),
      );
      await commitStep(
        'remote-primary',
        op.path,
        () async {
          await remote.put(
            op.path,
            await local.openStaged(primaryStage, token: token),
            entry: primary,
            condition: contentCondition,
            metadataCondition: metadataCondition,
            token: token,
          );
        },
      );
      await commitStep(
        'remote-preserve',
        preservePath,
        () async {
          await remote.put(
            preservePath,
            await local.openStaged(secondaryStage, token: token),
            entry: secondary,
            condition: const CreateOnly(),
            metadataCondition: const CreateOnly(),
            token: token,
          );
        },
      );
      await commitStep(
        'local-favorite-primary',
        op.path,
        () => local.updateFavorite(
          op.path,
          primary.favorite,
          token: token,
        ),
      );
      return;
    }

    final localCondition = op.localCondition;
    if (localCondition == null) {
      throw const NeedsRescan(
          'preserve-both primary local condition is unavailable');
    }
    // The remote version is primary. Stage both streams before changing the
    // local original, because the local original currently contains the
    // secondary version that must be copied to preservePath.
    final primaryStage = await stageConflictVersion(
      'stage-primary',
      op.path,
      primary,
      () => remote.read(op.path, token: token),
    );
    verifyStage(primaryStage, primary);
    final secondaryStage = await stageConflictVersion(
      'stage-secondary',
      preservePath,
      secondary,
      () => local.read(op.path, token: token),
    );
    verifyStage(secondaryStage, secondary);
    // Make the secondary discoverable on both sides before replacing the
    // original local object. If the process stops after this point, a fresh
    // scan still has both byte streams available for reconciliation.
    await commitStep(
      'local-preserve',
      preservePath,
      () => local.commitStaged(
        preservePath,
        secondaryStage,
        entry: secondary,
        condition: const LocalCreateOnly(),
        token: token,
      ),
      staged: secondaryStage,
      entry: secondary,
      condition: const LocalCreateOnly(),
    );
    await commitStep(
      'remote-preserve',
      preservePath,
      () async {
        await remote.put(
          preservePath,
          await local.openStaged(secondaryStage, token: token),
          entry: secondary,
          condition: const CreateOnly(),
          metadataCondition: const CreateOnly(),
          token: token,
        );
      },
    );
    await commitStep(
      'local-primary',
      op.path,
      () => local.commitStaged(
        op.path,
        primaryStage,
        entry: primary,
        condition: localCondition,
        token: token,
      ),
      staged: primaryStage,
      entry: primary,
      condition: localCondition,
    );
  }

  Future<void> _fail(SyncPlan p, SyncOperation o, JournalStore j, SyncClock c,
      Object e) async {
    try {
      await j.append(JournalRecord(
          planId: p.planId,
          generation: p.generation,
          operationId: o.id,
          path: o.path,
          state: JournalState.failed,
          atUtc: c.nowUtc,
          condition: o.condition?.fingerprint,
          metadataCondition: o.metadataCondition?.fingerprint,
          error: '$e'));
    } catch (_) {
      // Preserve the original error. A failed journal write is reconciled by
      // the next scan rather than masking a precondition or cancellation.
    }
  }
}
