import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

/// The small port used by [BrokerLocalObjectStore]. Tests can provide a fake
/// without constructing Flutter's MethodChannel; production injects
/// [FlutterBrokerMethodChannel].
abstract interface class BrokerMethodChannel {
  Future<T?> invokeMethod<T>(String method, [Object? arguments]);
}

final class FlutterBrokerMethodChannel implements BrokerMethodChannel {
  const FlutterBrokerMethodChannel([
    this.channel = const MethodChannel('synctune/probe'),
  ]);

  final MethodChannel channel;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) =>
      channel.invokeMethod<T>(method, arguments);
}

final class BrokerRoot {
  const BrokerRoot({required this.token, required this.generation});

  final String token;
  final String generation;
}

abstract interface class BrokerRootPort {
  BrokerRoot? get current;
}

final class MutableBrokerRootPort implements BrokerRootPort {
  MutableBrokerRootPort([this._current]);

  BrokerRoot? _current;

  @override
  BrokerRoot? get current => _current;

  set current(BrokerRoot? value) => _current = value;
}

final class BrokerError extends NeedsRescan {
  const BrokerError(this.code, this.message, [this.details]) : super(message);

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'BrokerError($code): $message';
}

/// A LocalObjectStore backed by the platform SAF or AppContainer broker.
///
/// The Dart side sees only an opaque root token, generation, relative path,
/// and opaque staging key. Native code owns URI/StorageFolder traversal and
/// all filesystem I/O. Every chunk call re-reads the current root, so a root
/// switch stops an in-flight operation at its next broker boundary.
final class BrokerLocalObjectStore
    implements LocalObjectStore, LocalPlanRecovery {
  BrokerLocalObjectStore({
    required this.channel,
    required this.root,
    this.chunkSize = 64 * 1024,
  }) {
    if (chunkSize < 1 || chunkSize > 1024 * 1024) {
      throw ArgumentError.value(chunkSize, 'chunkSize');
    }
  }

  final BrokerMethodChannel channel;
  final BrokerRootPort root;
  final int chunkSize;

  BrokerRoot _requireRoot() {
    final value = root.current;
    if (value == null) {
      throw const BrokerError(
        'root_unavailable',
        'No authorized music root is active.',
      );
    }
    return value;
  }

  void _ensurePinned(BrokerRoot pinned) {
    final current = root.current;
    if (current?.token != pinned.token ||
        current?.generation != pinned.generation) {
      throw const BrokerError(
        'root_changed',
        'The authorized root changed during this operation.',
      );
    }
  }

  Future<Map<Object?, Object?>> _callMap(
    String method,
    Map<String, Object?> arguments, {
    required BrokerRoot pinned,
  }) async {
    _ensurePinned(pinned);
    final merged = <String, Object?>{
      ...arguments,
      'token': pinned.token,
      'generation': pinned.generation,
    };
    try {
      final value = await channel.invokeMethod<Object?>(method, merged);
      // A denied response is still part of the pinned operation. Check the
      // root before interpreting it so an old run cannot turn a root switch
      // into an ordinary failure that the executor might continue past.
      _ensurePinned(pinned);
      if (value is! Map) {
        throw BrokerError('protocol', '$method returned a non-map response.');
      }
      final response = value.cast<Object?, Object?>();
      if (response['status'] != 'ok') {
        throw BrokerError(
          response['code']?.toString() ?? 'broker_denied',
          response['error']?.toString() ?? '$method was not accepted.',
        );
      }
      return response;
    } on PlatformException catch (error) {
      _ensurePinned(pinned);
      throw BrokerError(
        error.code,
        error.message ?? 'Platform broker call failed.',
        error.details,
      );
    } on MissingPluginException catch (error) {
      _ensurePinned(pinned);
      throw BrokerError(
        'unavailable',
        error.message ?? 'Platform broker is unavailable.',
      );
    }
  }

  int _intField(Map<Object?, Object?> value, String name) {
    final raw = value[name];
    if (raw is int) return raw;
    if (raw is num && raw == raw.toInt()) return raw.toInt();
    throw BrokerError(
      'protocol',
      'Broker response field "$name" is not an integer.',
    );
  }

  Uint8List _bytesField(Map<Object?, Object?> value) {
    final raw = value['bytes'];
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    throw const BrokerError('protocol', 'Broker response has no byte chunk.');
  }

  Stream<List<int>> _chunks(
    String method,
    Map<String, Object?> arguments, {
    required BrokerRoot pinned,
    required CancellationToken token,
  }) async* {
    var offset = 0;
    String? readHandle;
    try {
      while (true) {
        token.throwIfCancelled();
        final response = await _callMap(method, <String, Object?>{
          ...arguments,
          'offset': offset,
          'maxBytes': chunkSize,
          'readHandle': ?readHandle,
        }, pinned: pinned);
        readHandle = response['readHandle']?.toString() ?? readHandle;
        token.throwIfCancelled();
        final bytes = _bytesField(response);
        final next = _intField(response, 'nextOffset');
        if (bytes.length > chunkSize ||
            next < offset ||
            next - offset != bytes.length) {
          throw const BrokerError(
            'protocol',
            'Broker returned a non-contiguous chunk.',
          );
        }
        if (bytes.isNotEmpty) yield bytes;
        offset = next;
        final eof = response['eof'];
        if (eof is! bool) {
          throw const BrokerError(
            'protocol',
            'Broker response has no boolean EOF field.',
          );
        }
        if (bytes.isEmpty && !eof) {
          throw const BrokerError(
            'protocol',
            'Broker returned an empty non-EOF chunk.',
          );
        }
        if (eof) return;
      }
    } finally {
      // Android owns a sequential stream. Older/Windows brokers keep the
      // offset protocol and omit this handle. Close even after cancellation.
      if (readHandle != null) {
        try {
          await channel.invokeMethod<Object?>('localCloseRead', {
            'token': pinned.token,
            'generation': pinned.generation,
            'readHandle': readHandle,
          });
        } catch (_) {
          // The native broker also closes EOF, stale and expired sessions.
        }
      }
    }
  }

  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final pinned = _requireRoot();
    return _chunks(
      'localReadChunk',
      <String, Object?>{'path': path.value},
      pinned: pinned,
      token: token,
    );
  }

  @override
  Future<StagedObject> stage(
    SyncPath path,
    Stream<List<int>> content, {
    required String expectedSha256,
    CancellationToken token = const NeverCancelled(),
  }) async {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expectedSha256)) {
      throw const BrokerError(
        'invalid_hash',
        'A complete SHA-256 hash is required.',
      );
    }
    token.throwIfCancelled();
    final pinned = _requireRoot();
    final started = await _callMap('localStageBegin', <String, Object?>{
      'path': path.value,
    }, pinned: pinned);
    final key = started['key']?.toString();
    if (key == null || key.isEmpty) {
      throw const BrokerError(
        'protocol',
        'Broker did not return a staging handle.',
      );
    }
    var offset = 0;
    await for (final chunk in content) {
      token.throwIfCancelled();
      if (chunk.isEmpty) continue;
      if (chunk.length > chunkSize) {
        // Keep every IPC payload bounded even when a remote adapter emits a
        // larger chunk than the configured broker chunk size.
        for (var start = 0; start < chunk.length; start += chunkSize) {
          token.throwIfCancelled();
          final end = start + chunkSize < chunk.length
              ? start + chunkSize
              : chunk.length;
          final part = Uint8List.fromList(chunk.sublist(start, end));
          final written = await _callMap('localStageWrite', <String, Object?>{
            'key': key,
            'offset': offset,
            'bytes': part,
          }, pinned: pinned);
          token.throwIfCancelled();
          final next = _intField(written, 'nextOffset');
          if (next != offset + part.length) {
            throw const BrokerError(
              'protocol',
              'Broker returned a non-contiguous staging offset.',
            );
          }
          offset = next;
          reportSyncBytes(token, offset);
        }
      } else {
        final written = await _callMap('localStageWrite', <String, Object?>{
          'key': key,
          'offset': offset,
          'bytes': Uint8List.fromList(chunk),
        }, pinned: pinned);
        token.throwIfCancelled();
        final next = _intField(written, 'nextOffset');
        if (next != offset + chunk.length) {
          throw const BrokerError(
            'protocol',
            'Broker returned a non-contiguous staging offset.',
          );
        }
        offset = next;
        reportSyncBytes(token, offset);
      }
    }
    token.throwIfCancelled();
    final finished = await _callMap('localStageFinish', <String, Object?>{
      'key': key,
      'expectedSha256': expectedSha256.toLowerCase(),
    }, pinned: pinned);
    token.throwIfCancelled();
    final actualKey = finished['key']?.toString();
    final hash = finished['sha256']?.toString();
    if (actualKey != key ||
        hash == null ||
        hash.toLowerCase() != expectedSha256.toLowerCase()) {
      throw const BrokerError(
        'protocol',
        'Broker returned an invalid staged object.',
      );
    }
    final length = _intField(finished, 'length');
    if (length < 0 || length != offset) {
      throw const BrokerError(
        'protocol',
        'Broker returned a staged length different from the bytes written.',
      );
    }
    return StagedObject(key: key, sha256: hash.toLowerCase(), length: length);
  }

  @override
  Future<Stream<List<int>>> openStaged(
    StagedObject staged, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final pinned = _requireRoot();
    return _chunks(
      'localOpenStagedChunk',
      <String, Object?>{'key': staged.key},
      pinned: pinned,
      token: token,
    );
  }

  @override
  Future<bool> verifyStaged(
    StagedObject staged, {
    required String expectedSha256,
    required int expectedLength,
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expectedSha256) ||
        expectedLength < 0) {
      throw const BrokerError(
        'invalid_hash',
        'A complete SHA-256 hash and non-negative length are required.',
      );
    }
    final pinned = _requireRoot();
    final response = await _callMap('localVerifyStaged', <String, Object?>{
      'key': staged.key,
      'expectedSha256': expectedSha256.toLowerCase(),
      'expectedLength': expectedLength,
    }, pinned: pinned);
    token.throwIfCancelled();
    final valid = response['valid'];
    final actualHash = response['sha256'];
    final actualLength = response['length'];
    if (valid is! bool ||
        actualHash is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(actualHash) ||
        actualLength is! int ||
        actualLength < 0) {
      throw const BrokerError(
        'protocol',
        'Broker returned invalid staged verification evidence.',
      );
    }
    final matches =
        actualHash.toLowerCase() == expectedSha256.toLowerCase() &&
        actualLength == expectedLength;
    if (valid != matches) {
      throw const BrokerError(
        'protocol',
        'Broker staged verification flag disagrees with its evidence.',
      );
    }
    return valid && matches;
  }

  @override
  Future<void> commitStaged(
    SyncPath path,
    StagedObject staged, {
    required SyncEntry entry,
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final pinned = _requireRoot();
    await _callMap('localCommitStaged', <String, Object?>{
      'path': path.value,
      'key': staged.key,
      'entry': <String, Object?>{
        'id': entry.id,
        'path': entry.path.value,
        'kind': entry.kind.name,
        'size': entry.size,
        'modifiedAtUtc': entry.modifiedAtUtc.toIso8601String(),
        'sha256': entry.sha256,
        'revision': entry.revision,
        'favorite': <String, Object?>{
          'value': entry.favorite.value,
          'lamport': entry.favorite.lamport,
          'deviceId': entry.favorite.deviceId,
        },
      },
      'condition': _conditionMap(condition),
    }, pinned: pinned);
    token.throwIfCancelled();
  }

  @override
  Future<void> delete(
    SyncPath path, {
    required LocalCondition condition,
    String? operationId,
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final pinned = _requireRoot();
    await _callMap('localDelete', <String, Object?>{
      'path': path.value,
      'backupKey': _backupKey(path, condition, operationId),
      'condition': _conditionMap(condition),
    }, pinned: pinned);
    token.throwIfCancelled();
  }

  @override
  Future<void> recoverPendingPlan(
    SyncRoot root,
    SyncPlan plan, {
    required Iterable<JournalRecord> journal,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final current = _requireRoot();
    if (current.token != root.id || current.generation != root.generation) {
      throw const BrokerError(
        'root_changed',
        'The authorized root changed before local recovery.',
      );
    }
    // A failed journal append is deliberately allowed after an external
    // mutation. Keep the newest staged evidence until a later committed
    // record supersedes it; otherwise a failed marker would hide the exact
    // bytes needed for recovery on the next launch.
    final latestStaged = <String, JournalRecord>{};
    final committed = <String>{};
    for (final record in journal) {
      if (record.state == JournalState.committed) {
        committed.add(record.operationId);
        latestStaged.remove(record.operationId);
      } else if (record.state == JournalState.staged &&
          !committed.contains(record.operationId)) {
        latestStaged[record.operationId] = record;
      }
    }
    for (final record in latestStaged.values) {
      token.throwIfCancelled();
      final match = _pendingLocalMutation(plan, record, latestStaged);
      if (match == null) continue;
      if (match.delete) {
        await delete(
          match.path,
          condition: match.condition,
          operationId: record.operationId,
          token: token,
        );
      } else {
        final key = match.stagingKey;
        final hash = match.newHash;
        final length = match.length;
        final entry = match.entry;
        if (key == null || hash == null || length == null || entry == null) {
          throw const BrokerError(
            'recovery_evidence_missing',
            'The interrupted local mutation has incomplete recovery evidence.',
          );
        }
        await commitStaged(
          match.path,
          StagedObject(key: key, sha256: hash, length: length),
          entry: entry,
          condition: match.condition,
          token: token,
        );
      }
    }
  }

  _PendingLocalMutation? _pendingLocalMutation(
    SyncPlan plan,
    JournalRecord record,
    Map<String, JournalRecord> latest,
  ) {
    for (final operation in plan.operations) {
      if (operation.id == record.operationId) {
        if (operation.kind == SyncOperationKind.deleteLocal &&
            operation.localCondition is LocalMatchSha256) {
          return _PendingLocalMutation.delete(
            operation.path,
            operation.localCondition! as LocalMatchSha256,
          );
        }
        if (operation.kind == SyncOperationKind.putRemoteToLocal &&
            operation.source != null &&
            operation.localCondition != null) {
          return _PendingLocalMutation.commit(
            operation.path,
            operation.source!,
            operation.localCondition!,
            record,
          );
        }
      }
      if (operation.kind != SyncOperationKind.conflict) continue;
      String? step;
      for (final candidate in const ['local-preserve', 'local-primary']) {
        if (conflictCheckpointId(operation, candidate) == record.operationId) {
          step = candidate;
          break;
        }
      }
      if (step == null) continue;
      final stageStep = step == 'local-preserve'
          ? 'stage-secondary'
          : 'stage-primary';
      final stageRecord = latest[conflictCheckpointId(operation, stageStep)];
      if (stageRecord?.stagingKey == null ||
          stageRecord?.sha256 == null ||
          stageRecord?.length == null) {
        return null;
      }
      final entry = step == 'local-preserve'
          ? operation.other
          : operation.source;
      final condition = step == 'local-preserve'
          ? const LocalCreateOnly()
          : operation.localCondition;
      final path = step == 'local-preserve'
          ? operation.preservePath
          : operation.path;
      if (entry == null || condition == null || path == null) return null;
      return _PendingLocalMutation.commit(path, entry, condition, stageRecord!);
    }
    return null;
  }

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    CancellationToken token = const NeverCancelled(),
  }) {
    throw const BrokerError(
      'unsupported',
      'The broker does not expose unconditional favorite metadata writes.',
    );
  }

  Map<String, Object?> _conditionMap(LocalCondition condition) =>
      switch (condition) {
        LocalCreateOnly() => <String, Object?>{'type': 'createOnly'},
        LocalMatchSha256(:final sha256) => <String, Object?>{
          'type': 'matchSha256',
          'sha256': sha256,
        },
        _ => throw const BrokerError(
          'invalid_condition',
          'Unknown local condition.',
        ),
      };

  String _backupKey(
    SyncPath path,
    LocalCondition condition,
    String? operationId,
  ) {
    final digest = sha256
        .convert(
          utf8.encode(
            '${path.value}\u0000${condition.fingerprint}\u0000${operationId ?? ''}',
          ),
        )
        .toString();
    return '${digest.substring(0, 8)}-${digest.substring(8, 12)}-'
        '${digest.substring(12, 16)}-${digest.substring(16, 20)}-'
        '${digest.substring(20, 32)}';
  }
}

final class _PendingLocalMutation {
  const _PendingLocalMutation._({
    required this.path,
    required this.condition,
    this.entry,
    this.stagingKey,
    this.newHash,
    this.length,
    this.delete = false,
  });

  factory _PendingLocalMutation.delete(
    SyncPath path,
    LocalMatchSha256 condition,
  ) => _PendingLocalMutation._(path: path, condition: condition, delete: true);

  factory _PendingLocalMutation.commit(
    SyncPath path,
    SyncEntry entry,
    LocalCondition condition,
    JournalRecord staged,
  ) => _PendingLocalMutation._(
    path: path,
    condition: condition,
    entry: entry,
    stagingKey: staged.stagingKey,
    newHash: staged.sha256 ?? entry.sha256,
    length: staged.length ?? entry.size,
  );

  final SyncPath path;
  final LocalCondition condition;
  final SyncEntry? entry;
  final String? stagingKey;
  final String? newHash;
  final int? length;
  final bool delete;
}
