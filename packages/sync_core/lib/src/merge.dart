import 'model.dart';

enum MergeChoice { unchanged, local, remote, preserveBoth }

final class MergeResult {
  const MergeResult(this.choice, {this.entry, this.other, this.preservePath});
  final MergeChoice choice;
  final SyncEntry? entry;
  final SyncEntry? other;
  final SyncPath? preservePath;
  bool get conflict => choice == MergeChoice.preserveBoth;
}

final class ThreeWayMerger {
  const ThreeWayMerger();
  MergeResult merge(
      {required SyncEntry? base,
      required SyncEntry? local,
      required SyncEntry? remote}) {
    if (local == null && remote == null) {
      return const MergeResult(MergeChoice.unchanged);
    }

    final localDeleted = local != null && local.isDeleted;
    final remoteDeleted = remote != null && remote.isDeleted;

    if (localDeleted && remoteDeleted) {
      final favorite = local.favorite.merge(remote.favorite);
      final chooseLocal = local.revision > remote.revision ||
          (local.revision == remote.revision &&
              _stableIdentityKey(local).compareTo(_stableIdentityKey(remote)) <= 0);
      final chosen =
          (chooseLocal ? local : remote).copyWith(favorite: favorite);
      return MergeResult(
        chooseLocal ? MergeChoice.local : MergeChoice.remote,
        entry: chosen,
      );
    }

    if (localDeleted) {
      final favorite = local.favorite.merge(
        remote?.favorite ??
            const FavoriteStamp(value: false, lamport: 0, deviceId: ''),
      );
      return MergeResult(
        MergeChoice.local,
        entry: local.copyWith(favorite: favorite),
      );
    }

    if (remoteDeleted) {
      final favorite = remote.favorite.merge(
        local?.favorite ??
            const FavoriteStamp(value: false, lamport: 0, deviceId: ''),
      );
      return MergeResult(
        MergeChoice.remote,
        entry: remote.copyWith(favorite: favorite),
      );
    }

    // A first sync can encounter the same bytes carrying independently
    // generated identities (for example, a local catalog UUID and a remote
    // descriptor UUID). Treat that as one version and choose the identity by
    // a stable key so both directions converge without making a duplicate
    // conflict copy. Favorites still merge independently of the file bytes.
    if (local != null &&
        remote != null &&
        _sameContent(local, remote)) {
      final localKey = _stableIdentityKey(local);
      final remoteKey = _stableIdentityKey(remote);
      final chooseLocal = localKey.compareTo(remoteKey) <= 0;
      final chosen = (chooseLocal ? local : remote).copyWith(
        favorite: local.favorite.merge(remote.favorite),
      );
      return MergeResult(
        chooseLocal ? MergeChoice.local : MergeChoice.remote,
        entry: chosen,
      );
    }
    if (_same(local, remote)) {
      return local == null
          ? const MergeResult(MergeChoice.unchanged)
          : MergeResult(MergeChoice.local, entry: local);
    }
    if (_same(local, base)) {
      return remote == null
          ? const MergeResult(MergeChoice.unchanged)
          : MergeResult(MergeChoice.remote, entry: remote);
    }
    if (_same(remote, base)) {
      return local == null
          ? const MergeResult(MergeChoice.unchanged)
          : MergeResult(MergeChoice.local, entry: local);
    }
    if (local == null) return MergeResult(MergeChoice.remote, entry: remote);
    if (remote == null) return MergeResult(MergeChoice.local, entry: local);
    final favorite = local.favorite.merge(remote.favorite);
    final localChanged = base == null || !local.contentEquals(base);
    final remoteChanged = base == null || !remote.contentEquals(base);
    if (local.id != remote.id ||
        (localChanged && remoteChanged && !local.contentEquals(remote))) {
      // Revision numbers are endpoint-local.  A deterministic content key
      // gives both devices the same primary/secondary ordering even when a
      // pair of edits reused the same stable entry id.
      final localKey = _stableConflictKey(local);
      final remoteKey = _stableConflictKey(remote);
      final edited = localKey.compareTo(remoteKey) <= 0 ? local : remote;
      final other = identical(edited, local) ? remote : local;
      final dot = edited.path.value.lastIndexOf('.');
      final stem =
          dot > 0 ? edited.path.value.substring(0, dot) : edited.path.value;
      final ext = dot > 0 ? edited.path.value.substring(dot) : '';
      final suffix = '${other.id}-${other.sha256 ?? other.kind.name}'
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      return MergeResult(MergeChoice.preserveBoth,
          entry: edited,
          other: other,
          preservePath: SyncPath.parse('$stem.sync-conflict-$suffix$ext'));
    }
    if (localChanged && !remoteChanged) {
      return MergeResult(MergeChoice.local,
          entry: local.copyWith(favorite: favorite));
    }
    if (remoteChanged && !localChanged) {
      return MergeResult(MergeChoice.remote,
          entry: remote.copyWith(favorite: favorite));
    }
    return MergeResult(MergeChoice.local,
        entry: local.copyWith(favorite: favorite));
  }

  bool _same(SyncEntry? a, SyncEntry? b) => a == null || b == null
      ? a == b
      : a.contentEquals(b) && a.favorite == b.favorite;

  String _stableConflictKey(SyncEntry entry) =>
      '${entry.id}\u0000${entry.sha256 ?? entry.kind.name}\u0000${entry.path.value}';

  bool _sameContent(SyncEntry a, SyncEntry b) =>
      a.path == b.path &&
      a.kind == b.kind &&
      a.size == b.size &&
      a.sha256 == b.sha256;

  String _stableIdentityKey(SyncEntry entry) =>
      '${entry.id}\u0000${entry.path.value}\u0000${entry.sha256 ?? entry.kind.name}';
}
