import 'model.dart';
import 'merge.dart';
import 'ports.dart';

enum SyncOperationKind {
  putLocalToRemote,
  putRemoteToLocal,
  updateFavoriteToRemote,
  updateFavoriteToLocal,
  deleteRemote,
  deleteLocal,
  conflict,
}

final class SyncOperation {
  const SyncOperation({
    required this.id,
    required this.kind,
    required this.path,
    required this.planId,
    required this.generation,
    this.source,
    this.other,
    this.remoteBefore,
    this.condition,
    this.metadataCondition,
    this.localCondition,
    this.preservePath,
    this.expectedLocalSha256,
    this.sourceIsLocal,
  });
  final String id;
  final SyncOperationKind kind;
  final SyncPath path;
  final String planId;
  final String generation;
  final SyncEntry? source;
  final SyncEntry? other;

  /// The exact remote descriptor observed before a local-primary conflict
  /// writes its replacement. It is retained separately from [other], whose
  /// path and ID are rewritten for the preserved conflict copy.
  final SyncEntry? remoteBefore;

  /// Condition for the remote content object. Uploads carry an independent
  /// condition for their complete identity metadata below.
  final RemoteCondition? condition;
  final RemoteCondition? metadataCondition;
  final LocalCondition? localCondition;
  final SyncPath? preservePath;
  final String? expectedLocalSha256;

  /// Conflict materialization needs to know which side still owns the
  /// primary bytes. It is persisted so a resumed plan cannot guess after a
  /// partial commit.
  final bool? sourceIsLocal;
}

final class RemoteSnapshot {
  const RemoteSnapshot({
    required this.entries,
    required this.completeness,
    required this.generation,
    required this.capturedAtUtc,
  });
  final Map<SyncPath, RemoteObject> entries;
  final ScanCompleteness completeness;
  final String generation;
  final DateTime capturedAtUtc;
  bool get complete => completeness == ScanCompleteness.complete;
}

final class SyncPlan {
  const SyncPlan({
    required this.planId,
    required this.generation,
    required this.operations,
    required this.deletionsSuppressed,
    this.remoteNamespace = 'default',
  });
  final String planId;
  final String generation;
  final String remoteNamespace;
  final List<SyncOperation> operations;
  final bool deletionsSuppressed;
  Iterable<SyncOperation> get conflicts =>
      operations.where((x) => x.kind == SyncOperationKind.conflict);
}

/// Journal operation IDs for the durable substeps of a preserve-both conflict.
/// The suffix is stable within the persisted parent plan, so recovery can
/// distinguish staging from each independently committed copy.
String conflictCheckpointId(SyncOperation operation, String step) =>
    '${operation.id}::conflict::$step';

final class SyncPlanner {
  const SyncPlanner({this.merger = const ThreeWayMerger()});
  final ThreeWayMerger merger;

  SyncPlan plan({
    required String planId,
    required SyncRoot root,
    required SyncSnapshot local,
    required RemoteSnapshot remote,
    required SyncSnapshot? baseline,
  }) {
    if (local.generation != root.generation ||
        remote.generation != root.generation ||
        (baseline != null && baseline.generation != root.generation)) {
      throw const NeedsRescan('authorization generation changed');
    }
    if (local.completeness == ScanCompleteness.unauthorized ||
        remote.completeness == ScanCompleteness.unauthorized) {
      throw const NeedsRescan('authorization grant is unavailable');
    }

    final base = baseline?.entries ?? const <SyncPath, SyncEntry>{};
    final paths = <SyncPath>{
      ...base.keys,
      ...local.entries.keys,
      ...remote.entries.keys,
    };
    final operations = <SyncOperation>[];
    final reservedPaths = <SyncPath>{...paths};
    var deletionsSuppressed = false;
    final canDelete = local.complete && remote.complete;

    for (final path in paths.toList()..sort()) {
      final baseEntry = base[path];
      final localEntry = local[path] ??
          (local.complete && baseEntry != null
              ? _tombstone(baseEntry, local.capturedAtUtc)
              : null);
      final remoteObject = remote.entries[path];
      final remoteEntry = remoteObject?.entry ??
          (remote.complete && baseEntry != null
              ? _tombstone(baseEntry, remote.capturedAtUtc)
              : null);
      final result = merger.merge(
        base: baseEntry,
        local: localEntry,
        remote: remoteEntry,
      );
      if (result.conflict) {
        final preservePath =
            _allocatePreservePath(result.preservePath, reservedPaths);
        if (preservePath == null ||
            result.entry == null ||
            result.other == null) {
          throw const NeedsRescan('conflict has no safe preservation path');
        }
        reservedPaths.add(preservePath);
        final mergedFavorite =
            result.entry!.favorite.merge(result.other!.favorite);
        final primary = result.entry!.copyWith(favorite: mergedFavorite);
        final secondary = result.other!.copyWith(
          id: _conflictId(result.other!, preservePath),
          path: preservePath,
          favorite: mergedFavorite,
        );
        final sourceIsLocal = identical(result.entry, localEntry);
        final operationId = '$planId|${root.generation}|conflict|${path.value}|'
            '${primary.id}|${primary.sha256 ?? primary.kind.name}|'
            '${secondary.id}|${secondary.sha256 ?? secondary.kind.name}|'
            '${preservePath.value}|${sourceIsLocal ? 'local' : 'remote'}';
        operations.add(SyncOperation(
          id: operationId,
          kind: SyncOperationKind.conflict,
          path: path,
          planId: planId,
          generation: root.generation,
          source: primary,
          other: secondary,
          remoteBefore: remoteEntry,
          condition: sourceIsLocal ? _contentCondition(remoteObject) : null,
          metadataCondition:
              sourceIsLocal ? _metadataCondition(remoteObject) : null,
          localCondition: sourceIsLocal
              ? null
              : localEntry?.sha256 == null
                  ? const LocalCreateOnly()
                  : LocalMatchSha256(localEntry!.sha256!),
          preservePath: preservePath,
          sourceIsLocal: sourceIsLocal,
        ));
        continue;
      }
      if (result.choice == MergeChoice.unchanged || result.entry == null) {
        continue;
      }
      final chosen = result.entry!;
      final contentSameRemote =
          remoteEntry != null && chosen.contentEquals(remoteEntry);
      final favoriteSameRemote =
          remoteEntry != null && chosen.favorite == remoteEntry.favorite;
      final contentSameLocal =
          localEntry != null && chosen.contentEquals(localEntry);
      final favoriteSameLocal =
          localEntry != null && chosen.favorite == localEntry.favorite;

      if (chosen.kind == SyncEntryKind.directory &&
          (!contentSameRemote || !contentSameLocal)) {
        operations.add(_op(
          planId,
          root.generation,
          SyncOperationKind.conflict,
          path,
          chosen,
          remoteEntry ?? localEntry,
          null,
          null,
        ));
        continue;
      }

      if (result.choice == MergeChoice.local) {
        if (!contentSameRemote) {
          if (chosen.isDeleted && !canDelete) {
            deletionsSuppressed = true;
          } else if (!chosen.isDeleted || remoteEntry != null) {
            operations.add(_op(
              planId,
              root.generation,
              chosen.isDeleted
                  ? SyncOperationKind.deleteRemote
                  : SyncOperationKind.putLocalToRemote,
              path,
              chosen,
              remoteEntry,
              _contentCondition(remoteObject),
              null,
              null,
              _metadataCondition(remoteObject),
            ));
          }
        }
        if (!favoriteSameRemote && !chosen.isDeleted) {
          operations.add(_op(
            planId,
            root.generation,
            SyncOperationKind.updateFavoriteToRemote,
            path,
            chosen,
            null,
            _favoriteCondition(remoteObject),
            null,
          ));
        }
        if (!favoriteSameLocal && !chosen.isDeleted) {
          operations.add(_op(
            planId,
            root.generation,
            SyncOperationKind.updateFavoriteToLocal,
            path,
            chosen,
            null,
            null,
            null,
          ));
        }
      } else if (result.choice == MergeChoice.remote) {
        if (!contentSameLocal) {
          if (chosen.isDeleted && !canDelete) {
            deletionsSuppressed = true;
          } else if (!chosen.isDeleted || localEntry != null) {
            operations.add(_op(
              planId,
              root.generation,
              chosen.isDeleted
                  ? SyncOperationKind.deleteLocal
                  : SyncOperationKind.putRemoteToLocal,
              path,
              chosen,
              null,
              null,
              null,
              localEntry?.sha256,
            ));
          }
        }
        if (!favoriteSameLocal && !chosen.isDeleted) {
          operations.add(_op(
            planId,
            root.generation,
            SyncOperationKind.updateFavoriteToLocal,
            path,
            chosen,
            null,
            null,
            null,
          ));
        }
        if (!favoriteSameRemote && !chosen.isDeleted) {
          operations.add(_op(
            planId,
            root.generation,
            SyncOperationKind.updateFavoriteToRemote,
            path,
            chosen,
            null,
            _favoriteCondition(remoteObject),
            null,
          ));
        }
      }
    }
    return SyncPlan(
      planId: planId,
      generation: root.generation,
      remoteNamespace: root.remoteNamespace,
      operations: List.unmodifiable(operations),
      deletionsSuppressed: deletionsSuppressed,
    );
  }

  SyncEntry _tombstone(SyncEntry base, DateTime modifiedAtUtc) =>
      SyncEntry.tombstone(
        id: base.id,
        path: base.path,
        modifiedAtUtc: modifiedAtUtc.toUtc(),
        revision: base.revision + 1,
        favorite: base.favorite,
      );

  SyncPath? _allocatePreservePath(
      SyncPath? proposed, Set<SyncPath> reservedPaths) {
    if (proposed == null || !reservedPaths.contains(proposed)) {
      return proposed;
    }
    final value = proposed.value;
    final dot = value.lastIndexOf('.');
    final stem = dot > 0 ? value.substring(0, dot) : value;
    final ext = dot > 0 ? value.substring(dot) : '';
    for (var ordinal = 2;; ordinal++) {
      final candidate = SyncPath.parse('$stem-$ordinal$ext');
      if (!reservedPaths.contains(candidate)) return candidate;
    }
  }

  String _conflictId(SyncEntry entry, SyncPath preservePath) =>
      '${entry.id}:conflict:${entry.sha256 ?? entry.kind.name}:${preservePath.value}';

  RemoteCondition? _contentCondition(RemoteObject? object) {
    // A tombstone is an identity document whose content object has already
    // been removed. Recreating the live object must therefore be create-only;
    // treating its metadata ETag as a content precondition would either make
    // the upload unconditional or attempt to match a non-existent object.
    if (object == null || object.entry.isDeleted) return const CreateOnly();
    final etag = object.etag;
    return etag == null ? null : MatchEtag(etag);
  }

  RemoteCondition? _metadataCondition(RemoteObject? object) => object == null
      ? const CreateOnly()
      : object.metadataEtag == null
          ? null
          : MatchEtag(object.metadataEtag!);

  RemoteCondition? _favoriteCondition(RemoteObject? object) =>
      object == null || object.favoriteEtag == null
          ? const CreateOnly()
          : MatchEtag(object.favoriteEtag!);

  SyncOperation _op(
    String planId,
    String generation,
    SyncOperationKind kind,
    SyncPath path,
    SyncEntry? source,
    SyncEntry? other,
    RemoteCondition? condition,
    SyncPath? preservePath, [
    String? expectedLocalSha256,
    RemoteCondition? metadataCondition,
  ]) {
    final identity =
        '${source?.id ?? 'none'}:${source?.sha256 ?? 'none'}:${source?.favorite.lamport ?? 0}:${source?.favorite.deviceId ?? ''}:${other?.id ?? 'none'}';
    final operationId =
        '$planId|$generation|${kind.name}|${path.value}|$identity|${condition?.fingerprint ?? 'missing-condition'}|${metadataCondition?.fingerprint ?? 'missing-metadata-condition'}|${expectedLocalSha256 ?? 'local-absent'}';
    return SyncOperation(
      id: operationId,
      kind: kind,
      path: path,
      planId: planId,
      generation: generation,
      source: source,
      other: other,
      condition: condition,
      metadataCondition: metadataCondition,
      localCondition: kind == SyncOperationKind.putRemoteToLocal
          ? (expectedLocalSha256 == null
              ? const LocalCreateOnly()
              : LocalMatchSha256(expectedLocalSha256))
          : kind == SyncOperationKind.deleteLocal && expectedLocalSha256 != null
              ? LocalMatchSha256(expectedLocalSha256)
              : null,
      preservePath: preservePath,
      expectedLocalSha256: expectedLocalSha256,
    );
  }
}
