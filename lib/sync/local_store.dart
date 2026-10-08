import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'sync_model.dart';

abstract interface class LocalStore {
  String stageKey(String operationId);
  String backupKey(String operationId);
  Future<int?> modifiedMs(SyncPath path);
  Future<String?> stageHash(String operationId, CancellationToken token);
  Future<Stream<List<int>>> readStage(
    String operationId,
    CancellationToken token,
  );
  Future<String?> backupHash(String operationId, CancellationToken token);
  Future<SyncScanResult> scan(
    CancellationToken token, {
    SyncByteProgress? onBytes,
    SyncFileProgress? onFile,
  });
  Future<Stream<List<int>>> read(SyncPath path, CancellationToken token);
  Future<String?> hash(SyncPath path, CancellationToken token);
  Future<String> stage(
    String operationId,
    Stream<List<int>> source,
    String expectedHash,
    CancellationToken token, {
    SyncByteProgress? onBytes,
    SyncPath? path,
  });
  Future<void> commit(
    SyncPath path,
    String stageKey,
    String backupKey,
    String expectedHash,
    String? previousHash,
    CancellationToken token,
  );
  Future<void> deleteVerified(
    SyncPath path,
    String backupKey,
    String expectedHash,
    CancellationToken token,
  );
  Future<void> restore(
    SyncPath path,
    String backupKey,
    String expectedHash,
    CancellationToken token,
  );
  Future<bool> canResumeCommit(
    SyncPath path,
    String operationId,
    String expectedHash,
    String? previousHash,
    CancellationToken token,
  );
  Future<void> cleanup(PendingOperation operation, CancellationToken token);
}

abstract interface class ConfigurableLocalStore implements LocalStore {
  void configure(SyncSettings settings);
}

final class FileLocalStore implements LocalStore {
  FileLocalStore(String root, {this.isReparsePoint})
    : root = Directory(root).absolute;

  final Directory root;
  final Future<bool> Function(String absolutePath)? isReparsePoint;
  Directory get _internal =>
      Directory(_join(root.path, '.synctune-local-v2/sync'));

  @override
  String stageKey(String operationId) => operationId;
  @override
  String backupKey(String operationId) => operationId;

  String _join(String base, String child) =>
      '$base${Platform.pathSeparator}${child.replaceAll('/', Platform.pathSeparator)}';

  File _file(SyncPath path) {
    final target = File(_join(root.path, path.value));
    final normalizedRoot = root.absolute.path.toLowerCase().replaceAll(
      '\\',
      '/',
    );
    final normalizedTarget = target.absolute.path.toLowerCase().replaceAll(
      '\\',
      '/',
    );
    final rootPrefix = normalizedRoot.endsWith('/')
        ? normalizedRoot
        : '$normalizedRoot/';
    if (!normalizedTarget.startsWith(rootPrefix)) {
      throw SyncFailure('Path escapes the selected music folder.', path: path);
    }
    return target;
  }

  File _artifact(String key, String suffix) {
    if (!RegExp(r'^[0-9a-fA-F-]{16,64}$').hasMatch(key)) {
      throw SyncFailure('Invalid internal operation key.');
    }
    return File(_join(_internal.path, '$key.$suffix'));
  }

  @override
  Future<SyncScanResult> scan(
    CancellationToken token, {
    SyncByteProgress? onBytes,
    SyncFileProgress? onFile,
  }) async {
    if (await isReparsePoint?.call(root.path) == true) {
      throw const SyncFailure(
        'The selected music folder is a Windows reparse point.',
      );
    }
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType != FileSystemEntityType.directory) {
      throw SyncFailure(
        'The selected music folder is unavailable or is not a directory.',
      );
    }
    final files = <SyncFile>[];
    final occupiedPaths = <SyncOccupiedPath>[];
    final folded = <String, String>{};
    final pending = <({Directory directory, String prefix})>[
      (directory: root, prefix: ''),
    ];
    while (pending.isNotEmpty) {
      token.throwIfCancelled();
      final current = pending.removeLast();
      await for (final entity in current.directory.list(followLinks: false)) {
        token.throwIfCancelled();
        if (await isReparsePoint?.call(entity.path) == true) continue;
        final name = entity.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last;
        if (name.toLowerCase() == '.synctune' ||
            name.toLowerCase() == '.synctune-local' ||
            name.toLowerCase() == '.synctune-local-v2')
          continue;
        final relative = current.prefix.isEmpty
            ? name
            : '${current.prefix}/$name';
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.link) continue;
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.directory)
          continue;
        final path = SyncPath.parse(relative);
        occupiedPaths.add(
          SyncOccupiedPath(
            path: path.value,
            isDirectory: type == FileSystemEntityType.directory,
          ),
        );
        if (type == FileSystemEntityType.directory) {
          pending.add((directory: Directory(entity.path), prefix: relative));
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        if (!path.isMusic) continue;
        await onFile?.call(path);
        final key = relative.toLowerCase();
        final previous = folded[key];
        if (previous != null && previous != relative) {
          throw SyncFailure(
            'Windows case-insensitive path collision: "$previous" and "$relative".',
          );
        }
        folded[key] = relative;
        final file = File(entity.path);
        final stat = await file.stat();
        final digest = await _hashStream(
          file.openRead(),
          token,
          onBytes: onBytes == null ? null : (bytes) => onBytes(path, bytes),
        );
        files.add(
          SyncFile(
            path: path,
            sha256: digest.sha256,
            size: digest.length,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
          ),
        );
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    validateWindowsPathSet(files.map((file) => file.path));
    return SyncScanResult(files: files, occupiedPaths: occupiedPaths);
  }

  @override
  Future<Stream<List<int>>> read(SyncPath path, CancellationToken token) async {
    token.throwIfCancelled();
    await _checkPath(path);
    return _file(path).openRead();
  }

  @override
  Future<String?> hash(SyncPath path, CancellationToken token) async {
    token.throwIfCancelled();
    final file = _file(path);
    await _checkPath(path);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw SyncFailure('The target is not a regular file.', path: path);
    }
    return (await _hashStream(file.openRead(), token)).sha256;
  }

  @override
  Future<int?> modifiedMs(SyncPath path) async {
    await _checkPath(path);
    final file = _file(path);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file)
      return null;
    return (await file.stat()).modified.millisecondsSinceEpoch;
  }

  @override
  Future<String?> stageHash(String operationId, CancellationToken token) async {
    await _checkInternalPath();
    final stage = _artifact(operationId, 'part');
    await _checkArtifact(stage);
    if (!await stage.exists()) return null;
    return (await _hashStream(stage.openRead(), token)).sha256;
  }

  @override
  Future<Stream<List<int>>> readStage(
    String operationId,
    CancellationToken token,
  ) async {
    await _checkInternalPath();
    final stage = _artifact(operationId, 'part');
    await _checkArtifact(stage);
    if (!await stage.exists())
      throw const SyncFailure('The staged upload is missing.');
    token.throwIfCancelled();
    return stage.openRead();
  }

  @override
  Future<String?> backupHash(
    String operationId,
    CancellationToken token,
  ) async {
    await _checkInternalPath();
    final backup = _artifact(operationId, 'backup');
    await _checkArtifact(backup);
    if (!await backup.exists()) return null;
    return (await _hashStream(backup.openRead(), token)).sha256;
  }

  @override
  Future<String> stage(
    String operationId,
    Stream<List<int>> source,
    String expectedHash,
    CancellationToken token, {
    SyncByteProgress? onBytes,
    SyncPath? path,
  }) async {
    await _checkInternalPath();
    await _internal.create(recursive: true);
    final part = _artifact(operationId, 'part');
    await _checkArtifact(part);
    final existingLength = await part.exists() ? await part.length() : 0;
    final output = await part.open(mode: FileMode.append);
    RandomAccessFile? existing;
    if (existingLength > 0) existing = await part.open(mode: FileMode.read);
    final digest = _DigestSink();
    final converter = sha256.startChunkedConversion(digest);
    var offset = 0;
    try {
      await for (final chunk in source) {
        token.throwIfCancelled();
        if (chunk.isEmpty) continue;
        converter.add(chunk);
        if (onBytes != null && path != null) await onBytes(path, chunk.length);
        var start = 0;
        if (offset < existingLength) {
          final overlap = min(chunk.length, existingLength - offset);
          final saved = await existing!.read(overlap);
          if (saved.length != overlap)
            throw SyncFailure('A saved staging prefix is incomplete.');
          for (var index = 0; index < overlap; index++) {
            if (saved[index] != chunk[index])
              throw SyncFailure(
                'The source changed since the interrupted file operation.',
              );
          }
          start = overlap;
        }
        if (start < chunk.length)
          await output.writeFrom(chunk, start, chunk.length);
        offset += chunk.length;
        await output.flush();
      }
      converter.close();
      if (offset < existingLength)
        throw SyncFailure('The saved staging file is longer than its source.');
      final actual = digest.value.toString();
      if (actual != expectedHash)
        throw SyncFailure('Staged content failed its SHA-256 check.');
      return operationId;
    } catch (_) {
      rethrow;
    } finally {
      await existing?.close();
      await output.close();
    }
  }

  @override
  Future<void> commit(
    SyncPath path,
    String stageKey,
    String backupKey,
    String expectedHash,
    String? previousHash,
    CancellationToken token,
  ) async {
    await _checkInternalPath();
    final stage = _artifact(stageKey, 'part');
    final backup = _artifact(backupKey, 'backup');
    await _checkArtifact(stage);
    await _checkArtifact(backup);
    final target = _file(path);
    token.throwIfCancelled();
    await _checkPath(path, allowMissingLeaf: true);
    final stagedHash = (await _hashStream(stage.openRead(), token)).sha256;
    if (stagedHash != expectedHash)
      throw SyncFailure('Staged content changed before commit.', path: path);
    final currentHash = await hash(path, token);
    if (currentHash == expectedHash) {
      if (await backup.exists()) {
        final backupHash = (await _hashStream(backup.openRead(), token)).sha256;
        if (backupHash != previousHash)
          throw SyncFailure(
            'Committed file has an unexpected recovery backup.',
            path: path,
          );
      }
      return;
    }
    final hasMovedBackup =
        currentHash == null &&
        previousHash != null &&
        await backup.exists() &&
        (await _hashStream(backup.openRead(), token)).sha256 == previousHash;
    if (currentHash == null && previousHash == null && await backup.exists()) {
      throw SyncFailure(
        'An unknown recovery backup occupies the operation path.',
        path: path,
      );
    }
    if (currentHash != previousHash && !hasMovedBackup) {
      throw SyncFailure(
        'Local file changed after scanning; rescan is required.',
        path: path,
      );
    }
    await target.parent.create(recursive: true);
    await _checkPath(path, allowMissingLeaf: true);
    if (currentHash != null && !hasMovedBackup) {
      if (await backup.exists()) {
        final savedHash = (await _hashStream(backup.openRead(), token)).sha256;
        if (savedHash != currentHash)
          throw SyncFailure(
            'Recovery backup and target do not match.',
            path: path,
          );
        throw SyncFailure(
          'Recovery backup and target both exist; manual recovery is required.',
          path: path,
        );
      }
      if (await hash(path, token) != currentHash)
        throw SyncFailure(
          'Local file changed before it could be backed up.',
          path: path,
        );
      await target.rename(backup.path);
    }
    try {
      token.throwIfCancelled();
      await stage.rename(target.path);
      final writtenHash = await hash(path, token);
      if (writtenHash != expectedHash)
        throw SyncFailure(
          'Committed local file failed verification.',
          path: path,
        );
    } catch (_) {
      final targetType = await FileSystemEntity.type(
        target.path,
        followLinks: false,
      );
      if (targetType == FileSystemEntityType.notFound &&
          await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteVerified(
    SyncPath path,
    String backupKey,
    String expectedHash,
    CancellationToken token,
  ) async {
    final target = _file(path);
    final backup = _artifact(backupKey, 'backup');
    token.throwIfCancelled();
    await _checkInternalPath();
    await _checkArtifact(backup);
    await _internal.create(recursive: true);
    await _checkPath(path);
    final actual = await hash(path, token);
    if (actual == null) {
      if (await backup.exists() &&
          (await _hashStream(backup.openRead(), token)).sha256 == expectedHash)
        return;
      throw SyncFailure(
        'Local delete target disappeared before a recovery copy was confirmed.',
        path: path,
      );
    }
    if (actual != expectedHash)
      throw SyncFailure(
        'Local file changed before deletion; rescan is required.',
        path: path,
      );
    if (await backup.exists()) {
      final saved = (await _hashStream(backup.openRead(), token)).sha256;
      if (saved != expectedHash)
        throw SyncFailure(
          'Existing recovery backup has unexpected content.',
          path: path,
        );
      throw SyncFailure(
        'Both the delete target and its recovery copy exist.',
        path: path,
      );
    }
    if (await hash(path, token) != expectedHash)
      throw SyncFailure(
        'Local file changed before it could be backed up.',
        path: path,
      );
    await target.rename(backup.path);
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw SyncFailure('Local delete did not complete.', path: path);
    }
  }

  @override
  Future<void> restore(
    SyncPath path,
    String backupKey,
    String expectedHash,
    CancellationToken token,
  ) async {
    await _checkInternalPath();
    final backup = _artifact(backupKey, 'backup');
    await _checkArtifact(backup);
    final target = _file(path);
    if (!await backup.exists()) return;
    final backupHash = (await _hashStream(backup.openRead(), token)).sha256;
    if (backupHash != expectedHash)
      throw SyncFailure('Recovery copy has unexpected content.', path: path);
    final current = await hash(path, token);
    if (current != null) {
      if (current == expectedHash) return;
      throw SyncFailure(
        'A different file occupies the recovery path.',
        path: path,
      );
    }
    await target.parent.create(recursive: true);
    await _checkPath(path, allowMissingLeaf: true);
    await backup.rename(target.path);
  }

  @override
  Future<bool> canResumeCommit(
    SyncPath path,
    String operationId,
    String expectedHash,
    String? previousHash,
    CancellationToken token,
  ) async => false;

  @override
  Future<void> cleanup(
    PendingOperation operation,
    CancellationToken token,
  ) async {
    if (!operation.complete &&
        !(operation.needsRescan &&
            !operation.localDone &&
            !operation.remoteDone))
      throw SyncFailure(
        'Cannot clean artifacts before both sides are confirmed or a safe rescan is recorded.',
      );
    await _checkInternalPath();
    for (final item in <({String? key, String suffix, String? hash})>[
      (
        key: operation.localStage,
        suffix: 'part',
        hash: operation.expectedLocalHash,
      ),
      (
        key: operation.localBackup,
        suffix: 'backup',
        hash: operation.previousLocalHash,
      ),
    ]) {
      final key = item.key;
      if (key == null || key.isEmpty) continue;
      if (key != operation.id)
        throw SyncFailure(
          'Refusing to clean an artifact not owned by this operation.',
        );
      final file = _artifact(operation.id, item.suffix);
      await _checkArtifact(file);
      if (await file.exists()) {
        final expectedHash = item.hash;
        if (expectedHash == null ||
            (await _hashStream(file.openRead(), token)).sha256 !=
                expectedHash) {
          throw SyncFailure(
            'Unknown content remains in a SyncTune recovery file; it was kept.',
          );
        }
        await file.delete();
      }
    }
  }

  Future<void> _checkPath(
    SyncPath path, {
    bool allowMissingLeaf = false,
  }) async {
    if (await isReparsePoint?.call(root.path) == true) {
      throw const SyncFailure(
        'The selected folder is a Windows reparse point.',
      );
    }
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType != FileSystemEntityType.directory)
      throw const SyncFailure(
        'The selected folder is unavailable or is a reparse point.',
      );
    final segments = path.value.split('/');
    var cursor = root.path;
    for (var index = 0; index < segments.length; index++) {
      cursor = _join(cursor, segments[index]);
      if (await isReparsePoint?.call(cursor) == true) {
        throw SyncFailure(
          'A Windows reparse point blocks this music path.',
          path: path,
        );
      }
      final type = await FileSystemEntity.type(cursor, followLinks: false);
      if (type == FileSystemEntityType.link)
        throw SyncFailure(
          'A symbolic link or reparse point is not a music file.',
          path: path,
        );
      if (type == FileSystemEntityType.notFound &&
          (allowMissingLeaf || index < segments.length - 1))
        continue;
      if (index < segments.length - 1 &&
          type != FileSystemEntityType.directory) {
        throw SyncFailure('A parent path is not a directory.', path: path);
      }
    }
  }

  Future<void> _checkInternalPath() async {
    if (await isReparsePoint?.call(root.path) == true) {
      throw const SyncFailure(
        'The selected folder is a Windows reparse point.',
      );
    }
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType != FileSystemEntityType.directory)
      throw const SyncFailure(
        'The selected folder is unavailable or is a reparse point.',
      );
    final first = Directory(_join(root.path, '.synctune-local-v2'));
    if (await isReparsePoint?.call(first.path) == true) {
      throw const SyncFailure(
        'The SyncTune recovery folder is a Windows reparse point.',
      );
    }
    final firstType = await FileSystemEntity.type(
      first.path,
      followLinks: false,
    );
    if (firstType == FileSystemEntityType.link ||
        (firstType != FileSystemEntityType.notFound &&
            firstType != FileSystemEntityType.directory)) {
      throw const SyncFailure(
        'The SyncTune recovery folder is not a safe directory.',
      );
    }
    final secondType = await FileSystemEntity.type(
      _internal.path,
      followLinks: false,
    );
    if (await isReparsePoint?.call(_internal.path) == true) {
      throw const SyncFailure(
        'The SyncTune recovery folder is a Windows reparse point.',
      );
    }
    if (secondType == FileSystemEntityType.link ||
        (secondType != FileSystemEntityType.notFound &&
            secondType != FileSystemEntityType.directory)) {
      throw const SyncFailure(
        'The SyncTune recovery folder is not a safe directory.',
      );
    }
  }

  Future<void> _checkArtifact(File file) async {
    if (await isReparsePoint?.call(file.path) == true) {
      throw const SyncFailure(
        'A SyncTune recovery artifact is a Windows reparse point.',
      );
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file)) {
      throw const SyncFailure(
        'A SyncTune recovery artifact is not a regular file.',
      );
    }
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value =>
      _value ?? (throw StateError('Hash conversion produced no digest.'));
  @override
  void add(Digest value) => _value = value;
  @override
  void close() {}
}

final class _HashedContent {
  const _HashedContent(this.sha256, this.length);
  final String sha256;
  final int length;
}

Future<_HashedContent> _hashStream(
  Stream<List<int>> stream,
  CancellationToken token, {
  Future<void> Function(int bytes)? onBytes,
}) async {
  final sink = _DigestSink();
  final converter = sha256.startChunkedConversion(sink);
  var length = 0;
  await for (final chunk in stream) {
    token.throwIfCancelled();
    converter.add(chunk);
    length += chunk.length;
    await onBytes?.call(chunk.length);
  }
  converter.close();
  return _HashedContent(sink.value.toString(), length);
}
