import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:crypto/crypto.dart';

const musicExtensions = <String>{
  'mp3',
  'flac',
  'wav',
  'm4a',
  'aac',
  'ogg',
  'opus',
};

typedef SyncByteProgress = FutureOr<void> Function(SyncPath path, int bytes);
typedef SyncFileProgress = FutureOr<void> Function(SyncPath path);

final class SyncPath implements Comparable<SyncPath> {
  SyncPath.parse(String value) : value = _validate(value);

  final String value;

  static String _validate(String raw) {
    final value = raw;
    if (value.isEmpty ||
        value.startsWith('/') ||
        value.contains('\\') ||
        value.contains('\u0000') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      throw FormatException('Invalid relative path: $raw');
    }
    const reserved = <String>{
      'CON',
      'PRN',
      'AUX',
      'NUL',
      r'CONIN$',
      r'CONOUT$',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9',
    };
    final parts = value.split('/');
    for (final part in parts) {
      final base = part.split('.').first.toUpperCase();
      final normalizedBase = base.replaceFirstMapped(
        RegExp(r'[¹²³]$'),
        (match) => const {'¹': '1', '²': '2', '³': '3'}[match[0]!]!,
      );
      if (part.isEmpty ||
          part == '.' ||
          part == '..' ||
          part.endsWith('.') ||
          part.endsWith(' ') ||
          part.contains(':') ||
          RegExp(r'[\u0000-\u001F<>"|?*]').hasMatch(part) ||
          reserved.contains(base) ||
          const {
            'COM1',
            'COM2',
            'COM3',
            'LPT1',
            'LPT2',
            'LPT3',
          }.contains(normalizedBase)) {
        throw FormatException('Unsupported path segment "$part" in "$raw"');
      }
      if (part.length > 255) {
        throw FormatException(
          'Path segment exceeds Windows filename limits: "$part"',
        );
      }
    }
    return parts.join('/');
  }

  String get name => value.split('/').last;
  String get parent =>
      value.contains('/') ? value.substring(0, value.lastIndexOf('/')) : '';
  bool get isMusic =>
      musicExtensions.contains(name.split('.').last.toLowerCase());
  SyncPath child(String name) =>
      SyncPath.parse(value.isEmpty ? name : '$value/$name');

  @override
  int compareTo(SyncPath other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) => other is SyncPath && value == other.value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

final class SyncCancelled implements Exception {
  const SyncCancelled();
  @override
  String toString() => 'Synchronization was cancelled.';
}

final class SyncFailure implements Exception {
  const SyncFailure(
    this.message, {
    this.path,
    this.statusCode,
    this.conditionalWriteRejected = false,
    this.retryable = false,
  });
  final String message;
  final SyncPath? path;
  final int? statusCode;
  final bool conditionalWriteRejected;

  /// True for a dropped connection or timeout on a read-only request, where
  /// repeating the same request cannot change either store.
  final bool retryable;
  @override
  String toString() => path == null ? message : '$message (${path!.value})';
}

final class CancellationToken {
  final Completer<void> _cancelled = Completer<void>();
  final Set<void Function()> _listeners = <void Function()>{};
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (_cancelled.isCompleted) return;
    _cancelled.complete();
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void Function() listen(void Function() listener) {
    if (_cancelled.isCompleted) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void throwIfCancelled() {
    if (isCancelled) throw const SyncCancelled();
  }
}

final class SyncFile {
  const SyncFile({
    required this.path,
    required this.sha256,
    required this.size,
    this.modifiedMs = 0,
    this.etag,
    this.cachedFile,
  });
  final SyncPath path;
  final String sha256;
  final int size;
  final int modifiedMs;
  final String? etag;
  final File? cachedFile;
  bool get hasStrongEtag =>
      etag != null && RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(etag!);
}

final class SyncOccupiedPath {
  const SyncOccupiedPath({required this.path, required this.isDirectory});

  final String path;
  final bool isDirectory;
}

final class SyncScanResult {
  const SyncScanResult({required this.files, required this.occupiedPaths});

  final List<SyncFile> files;
  final List<SyncOccupiedPath> occupiedPaths;
}

/// Content hashes computed by an earlier, unfinished scan.
///
/// Each hash is written as soon as one file has been read, so an interrupted
/// scan can continue without reading the same content again. A hash is only
/// returned while the identifying metadata still matches: size and
/// modification time for local files, the strong ETag for WebDAV files. The
/// store is cleared after a fully verified sync, so a normal sync still reads
/// every local file; only a resumed scan relies on the metadata match, and the
/// final verification (which never reuses entries) re-reads everything.
abstract interface class ScanCheckpoint {
  String? localHash(
    SyncPath path, {
    required int size,
    required int modifiedMs,
  });
  ({String sha256, int size})? remoteFile(
    SyncPath path, {
    required String etag,
    int? size,
  });
  void recordLocal(
    SyncPath path, {
    required String sha256,
    required int size,
    required int modifiedMs,
  });
  void recordRemote(
    SyncPath path, {
    required String sha256,
    required int size,
    required String etag,
  });
}

void validateSyncTargetPaths(
  Iterable<SyncPath> targets, {
  required Iterable<SyncOccupiedPath> local,
  required Iterable<SyncOccupiedPath> remote,
}) {
  final localIndex = _indexOccupiedPaths(local);
  final remoteIndex = _indexOccupiedPaths(remote);
  for (final target in targets) {
    final parts = target.value.split('/');
    for (var index = 0; index < parts.length; index++) {
      final path = parts.take(index + 1).join('/');
      final directory = index < parts.length - 1;
      final key = path.toLowerCase();
      final localMatches = localIndex[key] ?? const <SyncOccupiedPath>[];
      final remoteMatches = remoteIndex[key] ?? const <SyncOccupiedPath>[];
      _validateOccupiedMatch(path, directory, localMatches, target, 'local');
      _validateOccupiedMatch(path, directory, remoteMatches, target, 'WebDAV');
      if (localMatches.isNotEmpty &&
          remoteMatches.isNotEmpty &&
          localMatches.single.path != remoteMatches.single.path) {
        throw SyncFailure(
          'The two folders use different capitalization for the same path: '
          '"${localMatches.single.path}" and "${remoteMatches.single.path}".',
          path: target,
        );
      }
    }
  }
}

Map<String, List<SyncOccupiedPath>> _indexOccupiedPaths(
  Iterable<SyncOccupiedPath> paths,
) {
  final result = <String, List<SyncOccupiedPath>>{};
  for (final path in paths) {
    result
        .putIfAbsent(path.path.toLowerCase(), () => <SyncOccupiedPath>[])
        .add(path);
  }
  return result;
}

void _validateOccupiedMatch(
  String expectedPath,
  bool expectedDirectory,
  List<SyncOccupiedPath> matches,
  SyncPath target,
  String side,
) {
  if (matches.isEmpty) return;
  if (matches.length != 1 || matches.single.path != expectedPath) {
    final found = matches.map((item) => item.path).join('", "');
    throw SyncFailure(
      'The $side folder has a case-insensitive path collision: '
      '"$expectedPath" conflicts with "$found".',
      path: target,
    );
  }
  if (matches.single.isDirectory != expectedDirectory) {
    throw SyncFailure(
      'The $side path "${matches.single.path}" is a '
      '${matches.single.isDirectory ? 'folder' : 'file'} where the sync needs '
      'a ${expectedDirectory ? 'folder' : 'file'}.',
      path: target,
    );
  }
}

final class BaselineEntry {
  const BaselineEntry({
    required this.path,
    required this.sha256,
    required this.localModifiedMs,
    required this.remoteEtag,
    required this.remoteSize,
  });
  final SyncPath path;
  final String sha256;
  final int localModifiedMs;
  final String? remoteEtag;
  final int remoteSize;
}

final class SyncSettings {
  const SyncSettings({
    required this.localRoot,
    required this.localRootId,
    required this.localGeneration,
    required this.serverUrl,
    required this.remoteRoot,
    required this.username,
    required this.language,
  });
  final String localRoot;
  final String localRootId;
  final String localGeneration;
  final String serverUrl;
  final String remoteRoot;
  final String username;
  final String language;

  String get effectiveRemoteUrl {
    final base = Uri.parse(serverUrl.trim());
    final remote = remoteRoot.trim();
    final remoteSegments = remote.isEmpty || remote == '/'
        ? const <String>[]
        : remote.split('/').where((part) => part.isNotEmpty).toList();
    return base
        .replace(
          pathSegments: <String>[
            ...base.pathSegments.where((part) => part.isNotEmpty),
            ...remoteSegments,
          ],
          query: null,
          fragment: null,
        )
        .toString();
  }

  String get syncIdentity => <String>[
    localRootId,
    localGeneration,
    serverUrl.trim(),
    remoteRoot.trim(),
    username.trim(),
  ].join('\n');
}

final class SyncMusicTrack {
  const SyncMusicTrack({
    required this.path,
    required this.size,
    required this.modifiedMs,
  });

  final SyncPath path;
  final int size;
  final int modifiedMs;
}

enum SyncPhase {
  idle,
  recovering,
  scanning,
  comparing,
  transferring,
  verifying,
  saving,
  complete,
  cancelled,
  failed,
}

final class SyncProgress {
  const SyncProgress({
    this.phase = SyncPhase.idle,
    this.currentFile = '',
    this.filesDone = 0,
    this.fileCount,
    this.bytesDone = 0,
    this.totalBytes,
    this.error = '',
  });
  final SyncPhase phase;
  final String currentFile;
  final int filesDone;
  final int? fileCount;
  final int bytesDone;
  final int? totalBytes;
  final String error;
  bool get running =>
      phase != SyncPhase.idle &&
      phase != SyncPhase.complete &&
      phase != SyncPhase.cancelled &&
      phase != SyncPhase.failed;
  double? get fraction {
    final total = totalBytes;
    return total != null && total > 0
        ? (bytesDone / total).clamp(0.0, 1.0).toDouble()
        : null;
  }

  SyncProgress copyWith({
    SyncPhase? phase,
    String? currentFile,
    int? filesDone,
    int? fileCount,
    bool clearFileCount = false,
    int? bytesDone,
    int? totalBytes,
    bool clearTotalBytes = false,
    String? error,
  }) => SyncProgress(
    phase: phase ?? this.phase,
    currentFile: currentFile ?? this.currentFile,
    filesDone: filesDone ?? this.filesDone,
    fileCount: clearFileCount ? null : fileCount ?? this.fileCount,
    bytesDone: bytesDone ?? this.bytesDone,
    totalBytes: clearTotalBytes ? null : totalBytes ?? this.totalBytes,
    error: error ?? this.error,
  );
}

final class PendingOperation {
  const PendingOperation({
    required this.id,
    required this.path,
    required this.kind,
    required this.expectedLocalHash,
    required this.expectedRemoteHash,
    required this.expectedSize,
    required this.previousLocalHash,
    required this.previousRemoteHash,
    required this.previousRemoteEtag,
    required this.sourcePath,
    required this.sourceSide,
    required this.localStage,
    required this.localBackup,
    required this.remoteBackup,
    this.localDone = false,
    this.remoteDone = false,
    this.complete = false,
    this.needsRescan = false,
  });
  final String id;
  final SyncPath path;
  final String kind;
  final String? expectedLocalHash;
  final String? expectedRemoteHash;
  final int expectedSize;
  final String? previousLocalHash;
  final String? previousRemoteHash;
  final String? previousRemoteEtag;
  final SyncPath? sourcePath;
  final String? sourceSide;
  final String? localStage;
  final String? localBackup;
  final String? remoteBackup;
  final bool localDone;
  final bool remoteDone;
  final bool complete;
  final bool needsRescan;
}

String hashBytes(List<int> bytes) => sha256.convert(bytes).toString();

Map<SyncPath, SyncFile> indexFiles(
  Iterable<SyncFile> files, {
  required bool windowsCaseSensitive,
}) {
  final indexed = SplayTreeMap<SyncPath, SyncFile>();
  final folded = <String, SyncPath>{};
  for (final file in files) {
    if (indexed.containsKey(file.path)) {
      throw SyncFailure('Two files resolve to the same path.', path: file.path);
    }
    if (!windowsCaseSensitive) {
      final key = file.path.value.toLowerCase();
      final previous = folded[key];
      if (previous != null && previous != file.path) {
        throw SyncFailure(
          'Windows case-insensitive path collision: "${previous.value}" and "${file.path.value}".',
        );
      }
      folded[key] = file.path;
    }
    indexed[file.path] = file;
  }
  if (!windowsCaseSensitive) validateWindowsPathSet(indexed.keys);
  return UnmodifiableMapView(indexed);
}

void validateWindowsPathSet(Iterable<SyncPath> paths) {
  final spellings = <String, String>{};
  final files = <String>{};
  final values = <String>[];
  for (final path in paths) {
    final value = path.value;
    values.add(value);
    files.add(value.toLowerCase());
    final segments = value.split('/');
    for (var index = 1; index <= segments.length; index++) {
      final prefix = segments.take(index).join('/');
      final key = prefix.toLowerCase();
      final previous = spellings[key];
      if (previous != null && previous != prefix) {
        throw SyncFailure(
          'Windows case-insensitive path collision: "$previous" and "$prefix".',
        );
      }
      spellings[key] = prefix;
    }
  }
  for (final value in values) {
    final segments = value.split('/');
    for (var index = 1; index < segments.length; index++) {
      final parent = segments.take(index).join('/').toLowerCase();
      if (files.contains(parent)) {
        throw SyncFailure('A file conflicts with a directory at "$parent".');
      }
    }
  }
}
