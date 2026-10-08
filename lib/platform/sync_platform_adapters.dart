import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../sync/local_store.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_model.dart';
import '../sync/sync_platform.dart';

/// Direct platform binding for the one sync controller. Android owns SAF,
/// Keystore, and foreground-service work; Windows uses Dart IO and a small
/// Win32 channel for the picker and Credential Manager.
final class SyncPlatformAdapters
    implements
        SyncCredentialStore,
        SyncFolderPicker,
        SyncExecutionHost,
        SyncMusicLibrary {
  SyncPlatformAdapters({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('synctune/sync_platform');

  final MethodChannel channel;
  DateTime _lastNotificationUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  SyncPhase? _lastNotifiedPhase;

  void bind(SyncController controller) {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'cancelSync':
          controller.cancel();
          return null;
        case 'windowCloseRequested':
          await controller.cancelAndWait();
          await channel.invokeMethod<void>('allowWindowClose');
          return null;
        default:
          throw MissingPluginException(
            'Unsupported platform callback ${call.method}.',
          );
      }
    });
  }

  Future<String> databasePath() async {
    if (Platform.isAndroid || Platform.isWindows) {
      final path = await channel.invokeMethod<String>('stateDatabasePath');
      if (path == null || path.isEmpty) {
        throw const SyncFailure(
          'The platform did not provide a private database path.',
        );
      }
      return path;
    }
    throw const SyncFailure('SyncTune supports Android and Windows only.');
  }

  @override
  Future<SyncFolderSelection?> pick() async {
    final result = await channel.invokeMapMethod<String, Object?>('pickFolder');
    if (result == null) return null;
    final locator = result['locator'] as String? ?? '';
    final stableId = result['stableId'] as String? ?? locator;
    final generation = result['generation'] as String? ?? '';
    if (locator.isEmpty || stableId.isEmpty) {
      throw const SyncFailure(
        'The platform returned an invalid folder selection.',
      );
    }
    return SyncFolderSelection(
      locator: locator,
      stableId: stableId,
      generation: generation,
    );
  }

  Future<void> commitFolder(String? oldRoot, String newRoot) async {
    if (!Platform.isAndroid || oldRoot == null || oldRoot == newRoot) return;
    await channel.invokeMethod<void>('commitFolder', <String, Object?>{
      'oldRoot': oldRoot,
      'newRoot': newRoot,
    });
  }

  @override
  Future<String> read(SyncSettings settings) async {
    final value = await channel.invokeMethod<String>(
      'credentialRead',
      <String, Object?>{'identity': _credentialIdentity(settings)},
    );
    if (value == null || value.isEmpty) {
      throw const SyncFailure(
        'The WebDAV password is not saved. Enter it in Settings.',
      );
    }
    return value;
  }

  Future<bool> hasSavedCredential(SyncSettings settings) async =>
      await channel.invokeMethod<bool>('credentialExists', <String, Object?>{
        'identity': _credentialIdentity(settings),
      }) ??
      false;

  @override
  Future<void> write(SyncSettings settings, String secret) async {
    if (secret.isEmpty) throw const SyncFailure('Enter the WebDAV password.');
    await channel.invokeMethod<void>('credentialWrite', <String, Object?>{
      'identity': _credentialIdentity(settings),
      'secret': secret,
    });
  }

  @override
  Future<void> delete(SyncSettings settings) async {
    await channel.invokeMethod<void>('credentialDelete', <String, Object?>{
      'identity': _credentialIdentity(settings),
    });
  }

  @override
  Future<List<SyncMusicTrack>> listMusic(SyncSettings settings) async {
    if (Platform.isAndroid) {
      return _SafLocalStore(
        channel,
        settings.localRoot,
        settings.localGeneration,
      ).listMusic();
    }
    return _fileStore(settings).listMusic();
  }

  @override
  Future<void> deleteMusic(SyncSettings settings, SyncMusicTrack track) async {
    if (Platform.isAndroid) {
      await _SafLocalStore(
        channel,
        settings.localRoot,
        settings.localGeneration,
      ).deleteMusic(track);
    } else {
      await _fileStore(settings).deleteMusic(track);
    }
  }

  FileLocalStore _fileStore(SyncSettings settings) => FileLocalStore(
    settings.localRoot,
    isReparsePoint: (path) async =>
        await channel.invokeMethod<bool>('isReparsePoint', <String, Object?>{
          'path': path,
        }) ??
        false,
  );

  @override
  Future<void> start(SyncSettings settings) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('foregroundStart');
      _lastNotifiedPhase = null;
    }
  }

  @override
  Future<void> update(SyncProgress progress) async {
    if (!Platform.isAndroid || !progress.running) return;
    final now = DateTime.now();
    if (now.difference(_lastNotificationUpdate) <
            const Duration(milliseconds: 600) &&
        progress.phase == _lastNotifiedPhase) {
      return;
    }
    _lastNotificationUpdate = now;
    _lastNotifiedPhase = progress.phase;
    await channel.invokeMethod<void>('foregroundUpdate', <String, Object?>{
      'phase': progress.phase.name,
      'currentFile': progress.currentFile,
      'filesDone': progress.filesDone,
      'fileCount': progress.fileCount ?? 0,
      'bytesDone': progress.bytesDone,
      'totalBytes': progress.totalBytes ?? 0,
    });
  }

  @override
  Future<void> finish(SyncProgress progress) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('foregroundFinish', <String, Object?>{
        'success': progress.phase == SyncPhase.complete,
        'cancelled': progress.phase == SyncPhase.cancelled,
        'error': progress.error,
      });
    }
  }

  LocalStore createLocalStore() => _ConfiguredLocalStore(channel);
}

String _credentialIdentity(SyncSettings settings) =>
    sha256.convert(utf8.encode(settings.syncIdentity)).toString();

final class _ConfiguredLocalStore implements ConfigurableLocalStore {
  _ConfiguredLocalStore(this.channel);

  final MethodChannel channel;
  SyncSettings? _settings;
  LocalStore? _delegate;

  void _configure(SyncSettings settings) {
    if (_settings?.syncIdentity == settings.syncIdentity && _delegate != null) {
      return;
    }
    _settings = settings;
    _delegate = Platform.isAndroid
        ? _SafLocalStore(channel, settings.localRoot, settings.localGeneration)
        : FileLocalStore(
            settings.localRoot,
            isReparsePoint: (path) async =>
                await channel.invokeMethod<bool>(
                  'isReparsePoint',
                  <String, Object?>{'path': path},
                ) ??
                false,
          );
  }

  LocalStore get _store =>
      _delegate ??
      (throw StateError('The selected folder has not been configured.'));

  @override
  void configure(SyncSettings settings) => _configure(settings);
  @override
  String stageKey(String id) => _store.stageKey(id);
  @override
  String backupKey(String id) => _store.backupKey(id);
  @override
  Future<int?> modifiedMs(SyncPath path) => _store.modifiedMs(path);
  @override
  Future<String?> stageHash(String id, CancellationToken token) =>
      _store.stageHash(id, token);
  @override
  Future<Stream<List<int>>> readStage(String id, CancellationToken token) =>
      _store.readStage(id, token);
  @override
  Future<String?> backupHash(String id, CancellationToken token) =>
      _store.backupHash(id, token);
  @override
  Future<SyncScanResult> scan(
    CancellationToken token, {
    SyncByteProgress? onBytes,
    SyncFileProgress? onFile,
  }) => _store.scan(token, onBytes: onBytes, onFile: onFile);
  @override
  Future<Stream<List<int>>> read(SyncPath path, CancellationToken token) =>
      _store.read(path, token);
  @override
  Future<String?> hash(SyncPath path, CancellationToken token) =>
      _store.hash(path, token);
  @override
  Future<String> stage(
    String id,
    Stream<List<int>> source,
    String expected,
    CancellationToken token, {
    SyncByteProgress? onBytes,
    SyncPath? path,
  }) => _store.stage(id, source, expected, token, onBytes: onBytes, path: path);
  @override
  Future<void> commit(
    SyncPath path,
    String stageKey,
    String backupKey,
    String expected,
    String? previous,
    CancellationToken token,
  ) => _store.commit(path, stageKey, backupKey, expected, previous, token);
  @override
  Future<void> deleteVerified(
    SyncPath path,
    String backupKey,
    String expected,
    CancellationToken token,
  ) => _store.deleteVerified(path, backupKey, expected, token);
  @override
  Future<void> restore(
    SyncPath path,
    String backupKey,
    String expected,
    CancellationToken token,
  ) => _store.restore(path, backupKey, expected, token);
  @override
  Future<bool> canResumeCommit(
    SyncPath path,
    String operationId,
    String expected,
    String? previous,
    CancellationToken token,
  ) => _store.canResumeCommit(path, operationId, expected, previous, token);
  @override
  Future<void> cleanup(PendingOperation operation, CancellationToken token) =>
      _store.cleanup(operation, token);
}

final class _SafLocalStore implements LocalStore {
  _SafLocalStore(this.channel, this.root, this.generation);
  final MethodChannel channel;
  final String root;
  final String generation;

  Map<String, Object?> get _scope => <String, Object?>{
    'root': root,
    'generation': generation,
  };

  Future<Map<String, Object?>> _call(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    final result = await channel.invokeMapMethod<String, Object?>(
      method,
      <String, Object?>{..._scope, ...?args},
    );
    if (result == null) throw SyncFailure('$method returned no result.');
    return result;
  }

  Future<Map<String, Object?>> _callCancellable(
    String method,
    Map<String, Object?> args,
    CancellationToken token,
  ) async {
    token.throwIfCancelled();
    final id = _randomId();
    final removeCancel = token.listen(() {
      unawaited(
        channel.invokeMethod<void>('safCancelRequest', <String, Object?>{
          ..._scope,
          'requestId': id,
        }),
      );
    });
    try {
      return await _call(method, <String, Object?>{...args, 'requestId': id});
    } finally {
      removeCancel();
    }
  }

  @override
  String stageKey(String operationId) => operationId;
  @override
  String backupKey(String operationId) => operationId;

  @override
  Future<int?> modifiedMs(SyncPath path) async {
    final result = await _call('safStat', <String, Object?>{
      'path': path.value,
    });
    return result['modifiedMs'] as int?;
  }

  Future<List<SyncMusicTrack>> listMusic() async {
    final response = await _call('safListMusic');
    final raw = response['tracks'];
    if (raw is! List) {
      throw const SyncFailure('The SAF music list is incomplete.');
    }
    final tracks = <SyncMusicTrack>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const SyncFailure('The SAF music list contains an invalid item.');
      }
      final value = Map<String, Object?>.from(item.cast<String, Object?>());
      final path = SyncPath.parse(value['path'] as String);
      final size = value['size'];
      final modifiedMs = value['modifiedMs'];
      if (!path.isMusic || size is! num || modifiedMs is! num) {
        throw SyncFailure(
          'The SAF music list contains invalid metadata.',
          path: path,
        );
      }
      tracks.add(
        SyncMusicTrack(
          path: path,
          size: size.toInt(),
          modifiedMs: modifiedMs.toInt(),
        ),
      );
    }
    tracks.sort((left, right) => left.path.compareTo(right.path));
    return tracks;
  }

  Future<void> deleteMusic(SyncMusicTrack track) async {
    await _call('safDeleteMusic', <String, Object?>{
      'path': track.path.value,
      'expectedSize': track.size,
      'expectedModifiedMs': track.modifiedMs,
    });
  }

  @override
  Future<SyncScanResult> scan(
    CancellationToken token, {
    SyncByteProgress? onBytes,
    SyncFileProgress? onFile,
  }) async {
    token.throwIfCancelled();
    final id = _randomId();
    final removeCancel = token.listen(() {
      unawaited(
        channel.invokeMethod<void>('safCancelRequest', <String, Object?>{
          ..._scope,
          'requestId': id,
        }),
      );
    });
    try {
      final response = await _call('safScan', <String, Object?>{
        'requestId': id,
      });
      final raw = response['files'];
      final rawOccupied = response['occupiedPaths'];
      if (raw is! List) {
        throw const SyncFailure(
          'The SAF scanner returned an incomplete listing.',
        );
      }
      final files = <SyncFile>[];
      if (rawOccupied is! List) {
        throw const SyncFailure(
          'The SAF scanner did not return filesystem path occupancy.',
        );
      }
      final occupiedPaths = <SyncOccupiedPath>[];
      for (final entry in rawOccupied) {
        if (entry is! Map) {
          throw const SyncFailure('The SAF scanner returned an invalid path.');
        }
        final map = Map<String, Object?>.from(entry.cast<String, Object?>());
        final path = SyncPath.parse(map['path'] as String);
        final directory = map['isDirectory'];
        if (directory is! bool) {
          throw SyncFailure(
            'The SAF scanner returned an invalid path.',
            path: path,
          );
        }
        occupiedPaths.add(
          SyncOccupiedPath(path: path.value, isDirectory: directory),
        );
      }
      for (final entry in raw) {
        token.throwIfCancelled();
        if (entry is! Map) {
          throw const SyncFailure(
            'The SAF scanner returned an invalid file record.',
          );
        }
        final map = Map<String, Object?>.from(entry.cast<String, Object?>());
        final path = SyncPath.parse(map['path'] as String);
        final hash = map['sha256'] as String;
        if (!path.isMusic || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
          throw SyncFailure(
            'The SAF scanner returned invalid music content metadata.',
            path: path,
          );
        }
        await onFile?.call(path);
        await onBytes?.call(path, (map['size'] as num).toInt());
        files.add(
          SyncFile(
            path: path,
            sha256: hash,
            size: (map['size'] as num).toInt(),
            modifiedMs: (map['modifiedMs'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      return SyncScanResult(files: files, occupiedPaths: occupiedPaths);
    } finally {
      removeCancel();
    }
  }

  @override
  Future<Stream<List<int>>> read(
    SyncPath path,
    CancellationToken token,
  ) async => _readChunks(
    'safReadOpen',
    'safReadChunk',
    'safReadClose',
    token,
    <String, Object?>{'path': path.value},
  );

  @override
  Future<String?> hash(SyncPath path, CancellationToken token) async {
    final stat = await _call('safStat', <String, Object?>{'path': path.value});
    if (stat['exists'] == false) return null;
    final stream = await read(path, token);
    return _hash(stream, token);
  }

  @override
  Future<String?> stageHash(String operationId, CancellationToken token) async {
    token.throwIfCancelled();
    final response = await _callCancellable('safStageHash', <String, Object?>{
      'operationId': operationId,
    }, token);
    return response['sha256'] as String?;
  }

  @override
  Future<Stream<List<int>>> readStage(
    String operationId,
    CancellationToken token,
  ) async => _readChunks(
    'safStageReadOpen',
    'safReadChunk',
    'safReadClose',
    token,
    <String, Object?>{'operationId': operationId},
  );

  @override
  Future<String?> backupHash(
    String operationId,
    CancellationToken token,
  ) async {
    final response = await _callCancellable('safBackupHash', <String, Object?>{
      'operationId': operationId,
    }, token);
    return response['sha256'] as String?;
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
    final opened = await _callCancellable('safStageBegin', <String, Object?>{
      'operationId': operationId,
    }, token);
    final existingLength = (opened['length'] as num?)?.toInt() ?? 0;
    var sourceOffset = 0;
    var writeOffset = existingLength;
    final digestSink = _DigestSink();
    final digest = sha256.startChunkedConversion(digestSink);
    StreamIterator<List<int>>? saved;
    var savedChunk = const <int>[];
    var savedOffset = 0;
    if (existingLength > 0) {
      saved = StreamIterator<List<int>>(await readStage(operationId, token));
    }
    Future<Uint8List> readSaved(int count) async {
      final output = Uint8List(count);
      var written = 0;
      while (written < count) {
        if (savedOffset >= savedChunk.length) {
          if (!await saved!.moveNext()) {
            throw const SyncFailure(
              'The saved SAF staging prefix is truncated.',
            );
          }
          savedChunk = saved!.current;
          savedOffset = 0;
          if (savedChunk.isEmpty) continue;
        }
        final amount = min(count - written, savedChunk.length - savedOffset);
        output.setRange(written, written + amount, savedChunk, savedOffset);
        written += amount;
        savedOffset += amount;
      }
      return output;
    }

    try {
      await for (final chunk in source) {
        token.throwIfCancelled();
        if (chunk.isEmpty) continue;
        digest.add(chunk);
        final overlap = min(
          chunk.length,
          max(0, existingLength - sourceOffset),
        );
        if (overlap > 0) {
          final previous = await readSaved(overlap);
          for (var index = 0; index < overlap; index++) {
            if (previous[index] != chunk[index]) {
              throw const SyncFailure(
                'The source changed since the interrupted SAF staging operation.',
              );
            }
          }
        }
        if (overlap < chunk.length) {
          final remaining = Uint8List.sublistView(
            Uint8List.fromList(chunk),
            overlap,
          );
          await _callCancellable('safStageWrite', <String, Object?>{
            'operationId': operationId,
            'offset': writeOffset,
            'bytes': remaining,
          }, token);
          writeOffset += remaining.length;
        }
        sourceOffset += chunk.length;
        if (onBytes != null && path != null) await onBytes(path, chunk.length);
      }
      digest.close();
      if (sourceOffset < existingLength ||
          digestSink.value.toString() != expectedHash) {
        throw const SyncFailure('SAF staged content failed its SHA-256 check.');
      }
      await _callCancellable('safStageFinish', <String, Object?>{
        'operationId': operationId,
        'expectedSha256': expectedHash,
      }, token);
      return operationId;
    } finally {
      await saved?.cancel();
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
    token.throwIfCancelled();
    await _callCancellable('safCommit', <String, Object?>{
      'path': path.value,
      'operationId': stageKey,
      'expectedSha256': expectedHash,
      'previousSha256': previousHash,
    }, token);
  }

  @override
  Future<void> deleteVerified(
    SyncPath path,
    String backupKey,
    String expectedHash,
    CancellationToken token,
  ) async {
    token.throwIfCancelled();
    await _callCancellable('safDeleteVerified', <String, Object?>{
      'path': path.value,
      'operationId': backupKey,
      'expectedSha256': expectedHash,
    }, token);
  }

  @override
  Future<void> restore(
    SyncPath path,
    String backupKey,
    String expectedHash,
    CancellationToken token,
  ) async {
    token.throwIfCancelled();
    await _callCancellable('safRestore', <String, Object?>{
      'path': path.value,
      'operationId': backupKey,
      'expectedSha256': expectedHash,
    }, token);
  }

  @override
  Future<bool> canResumeCommit(
    SyncPath path,
    String operationId,
    String expectedHash,
    String? previousHash,
    CancellationToken token,
  ) async {
    final result = await _callCancellable(
      'safCanResumeCommit',
      <String, Object?>{
        'path': path.value,
        'operationId': operationId,
        'expectedSha256': expectedHash,
        'previousSha256': previousHash,
      },
      token,
    );
    return result['recoverable'] == true;
  }

  @override
  Future<void> cleanup(
    PendingOperation operation,
    CancellationToken token,
  ) async {
    if (!operation.complete &&
        !(operation.needsRescan &&
            !operation.localDone &&
            !operation.remoteDone)) {
      throw const SyncFailure('Cannot clean incomplete SAF recovery data.');
    }
    await _callCancellable('safCleanupOperation', <String, Object?>{
      'operationId': operation.id,
      'stageSha256': operation.expectedLocalHash,
      'backupSha256': operation.previousLocalHash,
    }, token);
  }

  Stream<List<int>> _readChunks(
    String openMethod,
    String chunkMethod,
    String closeMethod,
    CancellationToken token,
    Map<String, Object?> arguments,
  ) async* {
    token.throwIfCancelled();
    final opened = await _call(openMethod, arguments);
    final handle = opened['readHandle'] as String?;
    if (handle == null || handle.isEmpty) {
      throw const SyncFailure('The SAF file could not be opened.');
    }
    final removeCancel = token.listen(() {
      unawaited(
        channel.invokeMethod<void>(closeMethod, <String, Object?>{
          ..._scope,
          'readHandle': handle,
        }),
      );
    });
    try {
      var eof = false;
      while (!eof) {
        token.throwIfCancelled();
        final response = await _call(chunkMethod, <String, Object?>{
          'readHandle': handle,
          'maxBytes': 256 * 1024,
        });
        final raw = response['bytes'];
        if (raw is! Uint8List) {
          throw const SyncFailure('The SAF reader returned invalid file data.');
        }
        if (raw.isNotEmpty) yield raw;
        eof = response['eof'] == true;
      }
    } finally {
      removeCancel();
      await channel.invokeMethod<void>(closeMethod, <String, Object?>{
        ..._scope,
        'readHandle': handle,
      });
    }
  }
}

String _randomId() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

Future<String> _hash(Stream<List<int>> stream, CancellationToken token) async {
  final sink = _DigestSink();
  final converter = sha256.startChunkedConversion(sink);
  await for (final chunk in stream) {
    token.throwIfCancelled();
    converter.add(chunk);
  }
  converter.close();
  return sink.value.toString();
}

final class _DigestSink implements Sink<Digest> {
  Digest? _digest;
  Digest get value => _digest ?? (throw StateError('No digest was produced.'));
  @override
  void add(Digest value) => _digest = value;
  @override
  void close() {}
}
