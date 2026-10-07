import 'model.dart';
import 'planner.dart';
import 'executor.dart';
import 'ports.dart';

abstract interface class LocalSnapshotProvider {
  Future<SyncSnapshot> capture(SyncRoot root,
      {CancellationToken token = const NeverCancelled()});
}

abstract interface class RemoteSnapshotProvider {
  Future<RemoteSnapshot> capture(SyncRoot root,
      {CancellationToken token = const NeverCancelled()});
}

final class SyncRunResult {
  const SyncRunResult(
      {required this.plan,
      required this.report,
      required this.baselineConfirmed});
  final SyncPlan plan;
  final ExecutionReport report;
  final bool baselineConfirmed;

  /// A UI/runtime adapter may only report a successful sync after the
  /// coordinator has proved that both complete post-scan views agree and the
  /// confirmed baseline was durably saved. A completed operation list alone
  /// is insufficient: conflicts, suppressed deletes, or a failed post-scan
  /// leave the plan unsafe to report as finished.
  void requireConfirmed() {
    final unresolvedConflicts = plan.conflicts.any(
      (operation) =>
          !report.completed.contains(operation.id) &&
          !report.skipped.contains(operation.id),
    );
    if (!baselineConfirmed ||
        report.hasFailures ||
        unresolvedConflicts ||
        plan.deletionsSuppressed) {
      throw const NeedsRescan(
        'sync did not produce a confirmed post-scan baseline',
      );
    }
  }
}

final class SyncCoordinator {
  const SyncCoordinator(
      {this.planner = const SyncPlanner(),
      this.executor = const SyncExecutor()});
  final SyncPlanner planner;
  final SyncExecutor executor;
  Future<SyncRunResult> run(SyncRoot root,
      {required String planId,
      required LocalSnapshotProvider localSnapshots,
      required RemoteSnapshotProvider remoteSnapshots,
      required BaselineStore baseline,
      required LocalObjectStore local,
      required RemoteRepository remote,
      required JournalStore journal,
      PlanStore? plans,
      SyncClock clock = const SystemSyncClock(),
      CancellationToken token = const NeverCancelled()}) async {
    token.throwIfCancelled();
    reportSyncProgress(
        token, const SyncProgress(stage: 'Recovering previous sync'));
    final old = await baseline.load(root);
    token.throwIfCancelled();
    var recovered = plans == null ? null : await plans.loadUnfinishedPlan(root);
    token.throwIfCancelled();
    var recoveredRecords = recovered == null
        ? const <JournalRecord>[]
        : await journal.recordsFor(recovered.planId, recovered.generation);
    token.throwIfCancelled();
    if (recovered != null && remote is RemotePlanRecovery) {
      final recovery = remote as RemotePlanRecovery;
      final recoveredOperations = await recovery.recoverPendingPlan(
        root,
        recovered,
        journal: recoveredRecords,
        token: token,
      );
      for (final operationId in recoveredOperations) {
        token.throwIfCancelled();
        SyncOperation? operation;
        SyncPath? operationPath;
        for (final candidate in recovered.operations) {
          if (candidate.id == operationId) {
            operation = candidate;
            operationPath = candidate.path;
            break;
          }
          if (candidate.kind == SyncOperationKind.conflict &&
              candidate.preservePath != null) {
            const steps = <String>[
              'local-preserve',
              'remote-primary',
              'remote-preserve',
              'local-favorite-primary',
              'local-primary',
            ];
            for (final step in steps) {
              if (conflictCheckpointId(candidate, step) == operationId) {
                operation = candidate;
                operationPath = step.contains('preserve')
                    ? candidate.preservePath
                    : candidate.path;
                break;
              }
            }
            if (operation != null) break;
          }
        }
        final recoveredOperation = operation;
        final recoveredPath = operationPath;
        if (recoveredOperation == null || recoveredPath == null) {
          throw const NeedsRescan(
              'remote recovery returned an unknown operation');
        }
        await journal.append(JournalRecord(
          planId: recovered.planId,
          generation: recovered.generation,
          operationId: operationId,
          path: recoveredPath,
          state: JournalState.committed,
          atUtc: clock.nowUtc,
          condition: recoveredOperation.condition?.fingerprint,
          metadataCondition: recoveredOperation.metadataCondition?.fingerprint,
        ));
        token.throwIfCancelled();
      }
      recoveredRecords = await journal.recordsFor(
        recovered.planId,
        recovered.generation,
      );
      token.throwIfCancelled();
    }
    if (recovered != null && local is LocalPlanRecovery) {
      try {
        await (local as LocalPlanRecovery).recoverPendingPlan(
          root,
          recovered,
          journal: recoveredRecords,
          token: token,
        );
      } on NeedsRescan catch (error) {
        if (!_isRecoverableLocalDrift(error)) rethrow;
        // The durable evidence no longer describes the live bytes. Keep the
        // backup/conflict visible, retire the stale plan, and let the normal
        // complete scan create a fresh plan instead of replaying forever.
        await plans!.markPlanSuperseded(root, recovered.planId);
        recovered = null;
        recoveredRecords = const <JournalRecord>[];
      }
      token.throwIfCancelled();
    }
    reportSyncProgress(
        token, const SyncProgress(stage: 'Scanning local music'));
    final localView = await localSnapshots.capture(root, token: token);
    token.throwIfCancelled();
    reportSyncProgress(
        token, const SyncProgress(stage: 'Scanning cloud music'));
    final remoteView = await remoteSnapshots.capture(root, token: token);
    token.throwIfCancelled();
    if (recovered != null) {
      await _recoverConflictCompletions(
        recovered,
        localView,
        remoteView,
        recoveredRecords,
        journal,
        clock,
        token,
      );
      token.throwIfCancelled();
      recoveredRecords = await journal.recordsFor(
        recovered.planId,
        recovered.generation,
      );
      token.throwIfCancelled();
    }
    if (recovered != null &&
        !_planStillCurrent(
          recovered,
          localView,
          remoteView,
          recoveredRecords,
        )) {
      // Keep the old journal as evidence, but never replay a plan whose
      // source bytes or remote CAS observations no longer describe the
      // current snapshots. A new plan gets a fresh operation identity.
      await plans!.markPlanSuperseded(root, recovered.planId);
      token.throwIfCancelled();
      recovered = null;
    }
    reportSyncProgress(token, const SyncProgress(stage: 'Planning sync'));
    final plan = recovered ??
        planner.plan(
            planId: planId,
            root: root,
            baseline: old,
            local: localView,
            remote: remoteView);
    // Persist the complete immutable plan before the executor can stage bytes
    // or mutate either side. A failed plan write therefore leaves the data
    // untouched and a process restart can identify the exact operation set.
    if (plans != null) await plans.savePlan(root, plan);
    token.throwIfCancelled();
    final report = await executor.execute(plan,
        local: local,
        remote: remote,
        journal: journal,
        clock: clock,
        token: token);
    token.throwIfCancelled();
    var baselineConfirmed = false;
    if (!report.hasFailures &&
        !plan.deletionsSuppressed &&
        localView.complete &&
        remoteView.complete) {
      final unresolvedConflicts = plan.conflicts.any(
        (operation) =>
            !report.completed.contains(operation.id) &&
            !report.skipped.contains(operation.id),
      );
      if (unresolvedConflicts) {
        return SyncRunResult(
          plan: plan,
          report: report,
          baselineConfirmed: false,
        );
      }
      reportSyncProgress(
          token, const SyncProgress(stage: 'Verifying local music'));
      final afterLocal = await localSnapshots.capture(root, token: token);
      token.throwIfCancelled();
      reportSyncProgress(
          token, const SyncProgress(stage: 'Verifying cloud music'));
      final afterRemote = await remoteSnapshots.capture(root, token: token);
      token.throwIfCancelled();
      if (_same(afterLocal, afterRemote) &&
          afterLocal.generation == root.generation &&
          afterRemote.generation == root.generation) {
        token.throwIfCancelled();
        reportSyncProgress(
            token, const SyncProgress(stage: 'Saving sync result'));
        await baseline.saveConfirmed(root, afterLocal, planId: plan.planId);
        token.throwIfCancelled();
        baselineConfirmed = true;
        if (plans != null) {
          await plans.markPlanFinished(root, plan.planId);
          token.throwIfCancelled();
        }
      }
    }
    return SyncRunResult(
        plan: plan, report: report, baselineConfirmed: baselineConfirmed);
  }

  bool _same(SyncSnapshot local, RemoteSnapshot remote) {
    if (!local.complete ||
        !remote.complete ||
        local.entries.length != remote.entries.length) {
      return false;
    }
    for (final path in local.entries.keys) {
      final r = remote.entries[path]?.entry;
      if (r == null ||
          !local.entries[path]!.contentEquals(r) ||
          local.entries[path]!.favorite != r.favorite) {
        return false;
      }
    }
    return true;
  }

  bool _isRecoverableLocalDrift(NeedsRescan error) {
    final text = error.reason.toString().toLowerCase();
    const protectedSignals = <String>[
      'root_changed',
      'root_unavailable',
      'root_revoked',
      'recovery_evidence_missing',
      'permission',
      'authorized root',
    ];
    if (protectedSignals.any(text.contains)) return false;
    const driftSignals = <String>[
      'precondition',
      'backup and target both exist',
      'target missing',
      'content verification failed',
      'content changed',
      'needsrescan',
    ];
    return driftSignals.any(text.contains);
  }

  bool _planStillCurrent(
    SyncPlan plan,
    SyncSnapshot local,
    RemoteSnapshot remote,
    List<JournalRecord> records,
  ) {
    if (!local.complete ||
        !remote.complete ||
        plan.generation != local.generation ||
        plan.generation != remote.generation ||
        plan.remoteNamespace.isEmpty) {
      return false;
    }
    final checkpointRecords = <String, JournalRecord>{
      for (final record in records) record.operationId: record,
    };
    final committed = records
        .where((record) => record.state == JournalState.committed)
        .map((record) => record.operationId)
        .toSet();
    for (final operation in plan.operations) {
      final localEntry = local.entries[operation.path];
      final remoteObject = remote.entries[operation.path];
      final source = operation.source;
      if (committed.contains(operation.id)) {
        final effectCurrent = operation.kind == SyncOperationKind.conflict
            ? _conflictStillCurrent(
                operation,
                local,
                remote,
                checkpointRecords,
              )
            : _committedEffectCurrent(operation, localEntry, remoteObject);
        if (!effectCurrent) {
          return false;
        }
        // A committed journal row is usable only as evidence of its current
        // effect. Its original precondition is expected to be false after a
        // successful write, so do not re-apply that condition here.
        continue;
      }
      switch (operation.kind) {
        case SyncOperationKind.putLocalToRemote:
          if (source == null ||
              localEntry == null ||
              !localEntry.contentEquals(source) ||
              !_remoteConditionMatches(
                operation.condition,
                remoteObject?.etag,
                contentAbsent:
                    remoteObject == null || remoteObject.entry.isDeleted,
              ) ||
              !_remoteConditionMatches(
                operation.metadataCondition,
                remoteObject?.metadataEtag,
              )) {
            return false;
          }
        case SyncOperationKind.putRemoteToLocal:
          if (source == null ||
              remoteObject == null ||
              !remoteObject.entry.contentEquals(source) ||
              !_localConditionMatches(operation.localCondition, localEntry)) {
            return false;
          }
        case SyncOperationKind.deleteRemote:
          if (remoteObject == null ||
              !_remoteConditionMatches(
                  operation.condition, remoteObject.etag) ||
              !_remoteConditionMatches(
                operation.metadataCondition,
                remoteObject.metadataEtag,
              )) {
            return false;
          }
        case SyncOperationKind.deleteLocal:
          if (!_localConditionMatches(operation.localCondition, localEntry)) {
            return false;
          }
        case SyncOperationKind.updateFavoriteToRemote:
          if (source == null ||
              localEntry == null ||
              localEntry.favorite != source.favorite ||
              !_remoteConditionMatches(
                operation.condition,
                remoteObject?.favoriteEtag,
              )) {
            return false;
          }
        case SyncOperationKind.updateFavoriteToLocal:
          if (source == null ||
              localEntry == null ||
              !localEntry.contentEquals(source) ||
              remoteObject == null ||
              remoteObject.entry.favorite != source.favorite) {
            return false;
          }
        case SyncOperationKind.conflict:
          if (!_conflictStillCurrent(
            operation,
            local,
            remote,
            checkpointRecords,
          )) {
            return false;
          }
      }
    }
    return true;
  }

  Future<void> _recoverConflictCompletions(
    SyncPlan plan,
    SyncSnapshot local,
    RemoteSnapshot remote,
    List<JournalRecord> records,
    JournalStore journal,
    SyncClock clock,
    CancellationToken token,
  ) async {
    final latest = <String, JournalRecord>{
      for (final record in records) record.operationId: record,
    };
    for (final operation in plan.conflicts) {
      token.throwIfCancelled();
      final primary = operation.source;
      final secondary = operation.other;
      final preservePath = operation.preservePath;
      if (primary == null || secondary == null || preservePath == null) {
        continue;
      }
      final localPrimary =
          _entryMatches(local.entries[operation.path], primary);
      final remotePrimary = _entryMatches(
        remote.entries[operation.path]?.entry,
        primary,
      );
      final localSecondary = _entryMatches(
        local.entries[preservePath],
        secondary,
      );
      final remoteSecondary = _entryMatches(
        remote.entries[preservePath]?.entry,
        secondary,
      );
      final hasPrimaryStage =
          _hasStage(latest, operation, 'stage-primary', primary);
      final hasSecondaryStage =
          _hasStage(latest, operation, 'stage-secondary', secondary);
      final inferred = <(String, SyncPath)>[];
      if (operation.sourceIsLocal == true) {
        if (hasSecondaryStage && localSecondary) {
          inferred.add(('local-preserve', preservePath));
        }
        if (hasPrimaryStage && remotePrimary && localSecondary) {
          inferred.add(('remote-primary', operation.path));
        }
        if (hasSecondaryStage && remoteSecondary && remotePrimary) {
          inferred.add(('remote-preserve', preservePath));
        }
        if (localSecondary &&
            remoteSecondary &&
            remotePrimary &&
            local.entries[operation.path]?.favorite == primary.favorite) {
          inferred.add(('local-favorite-primary', operation.path));
        }
      } else if (operation.sourceIsLocal == false) {
        if (hasSecondaryStage && localSecondary) {
          inferred.add(('local-preserve', preservePath));
        }
        if (hasSecondaryStage && localSecondary && remoteSecondary) {
          inferred.add(('remote-preserve', preservePath));
        }
        if (hasPrimaryStage &&
            localPrimary &&
            localSecondary &&
            remoteSecondary) {
          inferred.add(('local-primary', operation.path));
        }
      }
      for (final (step, path) in inferred) {
        final id = conflictCheckpointId(operation, step);
        if (latest[id]?.state == JournalState.committed) continue;
        final record = JournalRecord(
          planId: plan.planId,
          generation: plan.generation,
          operationId: id,
          path: path,
          state: JournalState.committed,
          atUtc: clock.nowUtc,
        );
        await journal.append(record);
        token.throwIfCancelled();
        latest[id] = record;
      }
    }
  }

  bool _hasStage(
    Map<String, JournalRecord> records,
    SyncOperation operation,
    String step,
    SyncEntry expected,
  ) {
    final record = records[conflictCheckpointId(operation, step)];
    return record?.state == JournalState.staged &&
        record?.stagingKey != null &&
        record?.sha256 == expected.sha256 &&
        record?.length == expected.size;
  }

  bool _conflictStillCurrent(
    SyncOperation operation,
    SyncSnapshot local,
    RemoteSnapshot remote,
    Map<String, JournalRecord> records,
  ) {
    final primary = operation.source;
    final secondary = operation.other;
    final preservePath = operation.preservePath;
    if (primary == null ||
        secondary == null ||
        preservePath == null ||
        operation.sourceIsLocal == null) {
      return false;
    }
    bool done(String step) =>
        records[conflictCheckpointId(operation, step)]?.state ==
        JournalState.committed;
    final localOriginal = local.entries[operation.path];
    final remoteOriginal = remote.entries[operation.path]?.entry;
    final localCopy = local.entries[preservePath];
    final remoteCopy = remote.entries[preservePath]?.entry;

    bool expectedOrAbsent(
      SyncEntry? actual,
      SyncEntry expected,
      String step,
    ) {
      if (actual == null) return !done(step);
      return _hasStage(records, operation, 'stage-secondary', secondary) &&
          _entryMatches(actual, expected);
    }

    if (!expectedOrAbsent(localCopy, secondary, 'local-preserve') ||
        !expectedOrAbsent(remoteCopy, secondary, 'remote-preserve')) {
      return false;
    }
    if (done('local-preserve') && !_entryMatches(localCopy, secondary)) {
      return false;
    }
    if (done('remote-preserve') && !_entryMatches(remoteCopy, secondary)) {
      return false;
    }

    if (operation.sourceIsLocal!) {
      if (!_entryHasContentAt(localOriginal, primary, operation.path)) {
        return false;
      }
      if (!_entryHasContentAt(remoteOriginal, secondary, operation.path) &&
          !_entryMatches(remoteOriginal, primary)) {
        return false;
      }
      if (_entryMatches(remoteOriginal, primary) &&
          (!_hasStage(records, operation, 'stage-primary', primary) ||
              !localSecondaryPresent(localCopy, secondary) ||
              !done('remote-primary'))) {
        return false;
      }
      if (done('remote-primary') && !_entryMatches(remoteOriginal, primary)) {
        return false;
      }
      if (_entryMatches(remoteCopy, secondary) &&
          !_entryMatches(remoteOriginal, primary)) {
        return false;
      }
      if (done('remote-preserve') && !_entryMatches(remoteOriginal, primary)) {
        return false;
      }
      if (done('local-favorite-primary') &&
          localOriginal?.favorite != primary.favorite) {
        return false;
      }
      return true;
    }

    if (!_entryHasContentAt(remoteOriginal, primary, operation.path)) {
      return false;
    }
    if (!_entryHasContentAt(localOriginal, secondary, operation.path) &&
        !_entryMatches(localOriginal, primary)) {
      return false;
    }
    if (_entryMatches(localOriginal, primary) &&
        (!_hasStage(records, operation, 'stage-primary', primary) ||
            !localSecondaryPresent(localCopy, secondary) ||
            !_entryMatches(remoteCopy, secondary) ||
            !done('local-primary'))) {
      return false;
    }
    if (done('local-primary') && !_entryMatches(localOriginal, primary)) {
      return false;
    }
    return true;
  }

  bool localSecondaryPresent(SyncEntry? entry, SyncEntry secondary) =>
      _entryMatches(entry, secondary);

  bool _entryMatches(SyncEntry? actual, SyncEntry expected) =>
      actual != null &&
      actual.contentEquals(expected) &&
      actual.favorite == expected.favorite;

  bool _entryHasContentAt(
    SyncEntry? actual,
    SyncEntry expected,
    SyncPath path,
  ) =>
      actual != null &&
      actual.path == path &&
      !actual.isDeleted &&
      actual.kind == expected.kind &&
      actual.size == expected.size &&
      actual.sha256 == expected.sha256;

  bool _committedEffectCurrent(
    SyncOperation operation,
    SyncEntry? localEntry,
    RemoteObject? remoteObject,
  ) {
    final source = operation.source;
    switch (operation.kind) {
      case SyncOperationKind.putLocalToRemote:
        return source != null &&
            localEntry != null &&
            localEntry.contentEquals(source) &&
            localEntry.favorite == source.favorite &&
            remoteObject != null &&
            !remoteObject.entry.isDeleted &&
            remoteObject.entry.contentEquals(source) &&
            remoteObject.entry.favorite == source.favorite;
      case SyncOperationKind.putRemoteToLocal:
        return source != null &&
            remoteObject != null &&
            remoteObject.entry.contentEquals(source) &&
            remoteObject.entry.favorite == source.favorite &&
            localEntry != null &&
            localEntry.contentEquals(source) &&
            localEntry.favorite == source.favorite;
      case SyncOperationKind.updateFavoriteToRemote:
        return source != null &&
            localEntry != null &&
            localEntry.favorite == source.favorite &&
            remoteObject != null &&
            remoteObject.entry.favorite == source.favorite;
      case SyncOperationKind.updateFavoriteToLocal:
        return source != null &&
            remoteObject != null &&
            remoteObject.entry.favorite == source.favorite &&
            localEntry != null &&
            localEntry.favorite == source.favorite;
      case SyncOperationKind.deleteRemote:
        return (localEntry == null ||
                (source != null && localEntry.contentEquals(source))) &&
            (remoteObject == null || remoteObject.entry.isDeleted);
      case SyncOperationKind.deleteLocal:
        return (remoteObject == null ||
                (source != null && remoteObject.entry.contentEquals(source))) &&
            (localEntry == null || localEntry.isDeleted);
      case SyncOperationKind.conflict:
        return false;
    }
  }

  bool _remoteConditionMatches(
    RemoteCondition? condition,
    String? actual, {
    bool contentAbsent = false,
  }) =>
      switch (condition) {
        CreateOnly() => contentAbsent ? true : actual == null,
        MatchEtag(:final etag) => actual == etag,
        null => false,
        RemoteCondition() => false,
      };

  bool _localConditionMatches(LocalCondition? condition, SyncEntry? actual) =>
      switch (condition) {
        LocalCreateOnly() => actual == null,
        LocalMatchSha256(:final sha256) => actual?.sha256 == sha256,
        null => false,
        LocalCondition() => false,
      };
}
