import 'dart:collection';

import 'sync_model.dart';

enum ContentSide { local, remote }

final class DesiredPath {
  const DesiredPath({
    required this.path,
    required this.sha256,
    required this.size,
    required this.sourceSide,
    required this.sourcePath,
    required this.previousLocalHash,
    required this.previousRemoteHash,
    required this.localModifiedMs,
    required this.remoteEtag,
  });
  final SyncPath path;
  final String? sha256;
  final int size;
  final ContentSide? sourceSide;
  final SyncPath? sourcePath;
  final String? previousLocalHash;
  final String? previousRemoteHash;
  final int localModifiedMs;
  final String? remoteEtag;
}

final class SyncPlanner {
  const SyncPlanner();

  List<DesiredPath> plan({
    required Map<SyncPath, SyncFile> local,
    required Map<SyncPath, SyncFile> remote,
    required Map<SyncPath, BaselineEntry> baseline,
  }) {
    final paths = SplayTreeSet<SyncPath>()
      ..addAll(local.keys)
      ..addAll(remote.keys)
      ..addAll(baseline.keys);
    validateWindowsPathSet(<SyncPath>{...local.keys, ...remote.keys});
    final occupied = <SyncPath>{
      ...local.keys,
      ...remote.keys,
      ...baseline.keys,
    };
    final result = <SyncPath, DesiredPath>{};
    final conflictClaims = <SyncPath, String>{};
    for (final path in paths) {
      if (conflictClaims.containsKey(path)) continue;
      final l = local[path];
      final r = remote[path];
      final b = baseline[path];
      if (b == null) {
        if (l == null && r == null) continue;
        if (l == null) {
          result[path] = _entry(
            path,
            r!,
            r.sha256,
            ContentSide.remote,
            path,
            l,
            r,
          );
        } else if (r == null) {
          result[path] = _entry(
            path,
            l,
            l.sha256,
            ContentSide.local,
            path,
            l,
            r,
          );
        } else if (l.sha256 == r.sha256) {
          result[path] = _entry(
            path,
            l,
            l.sha256,
            ContentSide.local,
            path,
            l,
            r,
          );
        } else {
          final conflict = _allocateConflict(
            path,
            l.sha256,
            local,
            remote,
            occupied,
            conflictClaims,
          );
          occupied.add(conflict);
          final existingLocalConflict = local[conflict];
          final existingRemoteConflict = remote[conflict];
          if (!conflictClaims.containsKey(conflict)) {
            final preserved = _entry(
              conflict,
              l,
              l.sha256,
              ContentSide.local,
              path,
              existingLocalConflict,
              existingRemoteConflict,
            );
            // A chosen conflict name is an explicit preservation decision. It
            // takes precedence over the generic deletion rule for this path.
            result[conflict] = preserved;
            conflictClaims[conflict] = l.sha256;
          }
          result[path] = _entry(
            path,
            r,
            r.sha256,
            ContentSide.remote,
            path,
            l,
            r,
          );
        }
        continue;
      }

      if (l == null || r == null) {
        // A missing side after a complete scan represents a deletion. Deletion
        // wins even when the remaining side has changed since the baseline.
        result[path] = _entry(path, null, null, null, null, l, r);
        continue;
      }
      if (l.sha256 == r.sha256) {
        result[path] = _entry(path, l, l.sha256, ContentSide.local, path, l, r);
        continue;
      }
      final localChanged = l.sha256 != b.sha256;
      final remoteChanged = r.sha256 != b.sha256;
      if (localChanged && remoteChanged) {
        final conflict = _allocateConflict(
          path,
          l.sha256,
          local,
          remote,
          occupied,
          conflictClaims,
        );
        occupied.add(conflict);
        final existingLocalConflict = local[conflict];
        final existingRemoteConflict = remote[conflict];
        if (!conflictClaims.containsKey(conflict)) {
          result[conflict] = _entry(
            conflict,
            l,
            l.sha256,
            ContentSide.local,
            path,
            existingLocalConflict,
            existingRemoteConflict,
          );
          conflictClaims[conflict] = l.sha256;
        }
        result[path] = _entry(
          path,
          r,
          r.sha256,
          ContentSide.remote,
          path,
          l,
          r,
        );
      } else if (localChanged) {
        result[path] = _entry(path, l, l.sha256, ContentSide.local, path, l, r);
      } else {
        // This also accepts an edit made by another WebDAV client: remote
        // content is hashed during the scan whenever its strong ETag changed.
        result[path] = _entry(
          path,
          r,
          r.sha256,
          ContentSide.remote,
          path,
          l,
          r,
        );
      }
    }
    final decisions = result.values.toList()
      ..sort((a, b) {
        // Materialize both copies of a conflict before replacing the original.
        final aConflict = a.sourcePath != null && a.sourcePath != a.path;
        final bConflict = b.sourcePath != null && b.sourcePath != b.path;
        if (aConflict != bConflict) return aConflict ? -1 : 1;
        return a.path.compareTo(b.path);
      });
    return List<DesiredPath>.unmodifiable(decisions);
  }

  DesiredPath _entry(
    SyncPath path,
    SyncFile? winner,
    String? hash,
    ContentSide? side,
    SyncPath? sourcePath,
    SyncFile? local,
    SyncFile? remote,
  ) => DesiredPath(
    path: path,
    sha256: hash,
    size: winner?.size ?? 0,
    sourceSide: side,
    sourcePath: sourcePath,
    previousLocalHash: local?.sha256,
    previousRemoteHash: remote?.sha256,
    localModifiedMs: local?.modifiedMs ?? winner?.modifiedMs ?? 0,
    remoteEtag: remote?.etag,
  );

  SyncPath _allocateConflict(
    SyncPath original,
    String localHash,
    Map<SyncPath, SyncFile> local,
    Map<SyncPath, SyncFile> remote,
    Set<SyncPath> occupied,
    Map<SyncPath, String> claims,
  ) {
    final name = original.name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    final marker = ' (SyncTune conflict $localHash)';
    for (var suffix = 1; suffix < 100000; suffix++) {
      final number = suffix == 1 ? '' : ' $suffix';
      final fixedLength = marker.length + number.length + extension.length;
      if (fixedLength >= 255)
        throw SyncFailure(
          'A safe conflict copy name cannot fit within Windows filename limits.',
          path: original,
        );
      final safeStem = _truncate(stem, (255 - fixedLength).clamp(1, 255));
      final requested = SyncPath.parse(
        '${original.parent.isEmpty ? '' : '${original.parent}/'}$safeStem$marker$number$extension',
      );
      final localPath = local.keys
          .where(
            (path) => path.value.toLowerCase() == requested.value.toLowerCase(),
          )
          .firstOrNull;
      final remotePath = remote.keys
          .where(
            (path) => path.value.toLowerCase() == requested.value.toLowerCase(),
          )
          .firstOrNull;
      final candidate = localPath ?? remotePath ?? requested;
      final localContent = local[localPath ?? requested]?.sha256;
      final remoteContent = remote[remotePath ?? requested]?.sha256;
      if ((localContent == null || localContent == localHash) &&
          (remoteContent == null || remoteContent == localHash)) {
        final claim = claims[candidate];
        if (claim != null && claim != localHash) continue;
        try {
          validateWindowsPathSet(<SyncPath>{...occupied, requested});
        } on SyncFailure {
          continue;
        }
        return candidate;
      }
    }
    throw SyncFailure(
      'No safe conflict copy name is available.',
      path: original,
    );
  }

  String _truncate(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    var end = maxLength;
    if (end > 0 &&
        value.codeUnitAt(end - 1) >= 0xD800 &&
        value.codeUnitAt(end - 1) <= 0xDBFF)
      end--;
    return value.substring(0, end);
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
