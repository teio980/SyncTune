import 'model.dart';
import 'planner.dart';

abstract interface class CancellationToken {
  bool get isCancelled;
  void throwIfCancelled();
}

/// Optional asynchronous cancellation signal implemented by runtime sources.
/// Keeping this separate preserves compatibility with simple synchronous
/// tokens used by core tests and adapters.
abstract interface class CancellationSignal {
  Future<void>? get onCancel;
}

final class NeverCancelled implements CancellationToken {
  const NeverCancelled();
  @override
  bool get isCancelled => false;
  @override
  void throwIfCancelled() {}
}

final class SyncCancelled implements Exception {
  const SyncCancelled();
  @override
  String toString() => 'Sync operation cancelled.';
}

abstract interface class SyncClock {
  DateTime get nowUtc;
}

final class SystemSyncClock implements SyncClock {
  const SystemSyncClock();
  @override
  DateTime get nowUtc => DateTime.now().toUtc();
}

final class StagedObject {
  const StagedObject(
      {required this.key, required this.sha256, required this.length});
  final String key;
  final String sha256;
  final int length;
}

abstract interface class LocalObjectStore {
  Future<Stream<List<int>>> read(SyncPath path,
      {CancellationToken token = const NeverCancelled()});
  Future<StagedObject> stage(SyncPath path, Stream<List<int>> content,
      {required String expectedSha256,
      CancellationToken token = const NeverCancelled()});
  Future<Stream<List<int>>> openStaged(StagedObject staged,
      {CancellationToken token = const NeverCancelled()});
  Future<bool> verifyStaged(StagedObject staged,
      {required String expectedSha256,
      required int expectedLength,
      CancellationToken token = const NeverCancelled()});
  Future<void> commitStaged(SyncPath path, StagedObject staged,
      {required SyncEntry entry,
      required LocalCondition condition,
      CancellationToken token = const NeverCancelled()});
  Future<void> delete(SyncPath path,
      {required LocalCondition condition,
      CancellationToken token = const NeverCancelled()});
  Future<void> updateFavorite(SyncPath path, FavoriteStamp stamp,
      {CancellationToken token = const NeverCancelled()});
}

abstract class LocalCondition {
  const LocalCondition();
  String get fingerprint;
}

final class LocalCreateOnly extends LocalCondition {
  const LocalCreateOnly();
  @override
  String get fingerprint => 'local-absent';
}

final class LocalMatchSha256 extends LocalCondition {
  factory LocalMatchSha256(String sha256) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      throw FormatException('A complete SHA-256 hash is required.');
    }
    return LocalMatchSha256._(sha256.toLowerCase());
  }
  const LocalMatchSha256._(this.sha256);
  final String sha256;
  @override
  String get fingerprint => 'local-sha256:$sha256';
}

abstract class RemoteCondition {
  const RemoteCondition();
  String get fingerprint;
}

final class CreateOnly extends RemoteCondition {
  const CreateOnly();
  @override
  String get fingerprint => 'If-None-Match:*';
}

final class MatchEtag extends RemoteCondition {
  factory MatchEtag(String etag) {
    if (etag.length < 2 ||
        etag.codeUnitAt(0) != 0x22 ||
        etag.codeUnitAt(etag.length - 1) != 0x22) {
      throw FormatException('A strong quoted ETag is required.');
    }
    for (var i = 1; i < etag.length - 1; i++) {
      final code = etag.codeUnitAt(i);
      final valid = code == 0x21 ||
          (code >= 0x23 && code <= 0x7e) ||
          (code >= 0x80 && code <= 0xff);
      if (!valid) throw FormatException('A strong quoted ETag is required.');
    }
    return MatchEtag._(etag);
  }
  const MatchEtag._(this.etag);
  final String etag;
  @override
  String get fingerprint => 'If-Match:$etag';
}

final class RemoteObject {
  const RemoteObject(
      {required this.entry,
      required this.etag,
      this.metadataEtag,
      this.favoriteEtag});
  final SyncEntry entry;
  final String? etag;

  /// ETag for the complete identity/content metadata document.
  final String? metadataEtag;

  /// ETag for the independent favorite metadata document.
  final String? favoriteEtag;
}

abstract interface class RemoteRepository {
  Future<Stream<List<int>>> read(SyncPath path,
      {CancellationToken token = const NeverCancelled()});
  Future<String> put(SyncPath path, Stream<List<int>> content,
      {required SyncEntry entry,
      required RemoteCondition condition,
      required RemoteCondition metadataCondition,
      CancellationToken token = const NeverCancelled()});
  Future<void> delete(SyncPath path,
      {required MatchEtag condition,
      SyncEntry? tombstone,
      RemoteCondition? metadataCondition,
      CancellationToken token = const NeverCancelled()});
  Future<void> updateFavorite(SyncPath path, FavoriteStamp stamp,
      {required RemoteCondition condition,
      CancellationToken token = const NeverCancelled()});
}

/// Optional recovery capability for transports that commit content and its
/// identity metadata as separate CAS operations. A provider may reconcile an
/// unfinished operation before the next remote snapshot, but only when the
/// durable plan/journal evidence and the current remote bytes prove the
/// intended content. Returned IDs have their operation-level commit marker
/// appended by the coordinator after this call succeeds.
abstract interface class RemotePlanRecovery {
  Future<Set<String>> recoverPendingPlan(
    SyncRoot root,
    SyncPlan plan, {
    required Iterable<JournalRecord> journal,
    CancellationToken token = const NeverCancelled(),
  });
}

abstract interface class BaselineStore {
  Future<SyncSnapshot?> load(SyncRoot root);
  Future<void> saveConfirmed(SyncRoot root, SyncSnapshot snapshot,
      {required String planId});
}

enum JournalState { staged, committed, failed }

final class JournalRecord {
  const JournalRecord(
      {required this.planId,
      required this.generation,
      required this.operationId,
      required this.path,
      required this.state,
      required this.atUtc,
      this.stagingKey,
      this.sha256,
      this.length,
      this.condition,
      this.metadataCondition,
      this.error});
  final String planId;
  final String generation;
  final String operationId;
  final SyncPath path;
  final JournalState state;
  final DateTime atUtc;
  final String? stagingKey;
  final String? sha256;
  final int? length;
  final String? condition;
  final String? metadataCondition;
  final String? error;
}

abstract interface class JournalStore {
  Future<List<JournalRecord>> recordsFor(String planId, String generation);
  Future<void> append(JournalRecord record);
}

/// Durable plan boundary. Implementations persist a complete encoded plan
/// before the first staging or remote mutation. An unfinished plan is scoped
/// by the local root generation and remote namespace so a changed grant or
/// endpoint cannot resume operations against another data set.
abstract interface class PlanStore {
  Future<void> savePlan(SyncRoot root, SyncPlan plan);
  Future<SyncPlan?> loadUnfinishedPlan(SyncRoot root);
  Future<void> markPlanFinished(SyncRoot root, String planId);
  Future<void> markPlanSuperseded(SyncRoot root, String planId);
}

class NeedsRescan implements Exception {
  const NeedsRescan(this.reason);
  final Object reason;
  @override
  String toString() => 'Fresh scan required: $reason';
}

final class RemotePreconditionFailed implements Exception {
  const RemotePreconditionFailed(this.path);
  final SyncPath path;
  @override
  String toString() => 'Remote precondition failed: $path';
}
