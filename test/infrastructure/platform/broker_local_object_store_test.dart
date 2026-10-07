import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';
import 'package:synctune/infrastructure/platform/broker_local_object_store.dart';

const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherHash =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

final class _FakeChannel implements BrokerMethodChannel {
  final calls = <String>[];
  String? finishHash = _hash;
  bool failVerification = false;
  final deleteArguments = <Map<String, Object?>>[];
  void Function(String method, Map<String, Object?> arguments)? onCall;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(method);
    final map = (arguments as Map).cast<String, Object?>();
    onCall?.call(method, map);
    switch (method) {
      case 'localReadChunk':
        return <String, Object?>{
          'status': 'ok',
          'bytes': Uint8List.fromList(const [1, 2]),
          'nextOffset': 2,
          'eof': true,
        } as T;
      case 'localStageBegin':
        return <String, Object?>{'status': 'ok', 'key': 'stage-key'} as T;
      case 'localStageWrite':
        return <String, Object?>{
          'status': 'ok',
          'nextOffset':
              (map['offset'] as int) + (map['bytes'] as Uint8List).length,
        } as T;
      case 'localStageFinish':
        return <String, Object?>{
          'status': 'ok',
          'key': 'stage-key',
          'sha256': finishHash,
          'length': 2,
        } as T;
      case 'localVerifyStaged':
        return <String, Object?>{
          'status': 'ok',
          'valid': !failVerification,
          'sha256': failVerification ? _otherHash : _hash,
          'length': 2,
        } as T;
      case 'localDelete':
        deleteArguments.add(map);
        return <String, Object?>{'status': 'ok'} as T;
      default:
        return <String, Object?>{'status': 'ok'} as T;
    }
  }
}

void main() {
  test(
    'read reuses the native handle and closes it on consumer cancellation',
    () async {
      final channel = _SequentialReadChannel();
      final store = BrokerLocalObjectStore(
        channel: channel,
        root: MutableBrokerRootPort(
          const BrokerRoot(token: 'opaque', generation: 'g1'),
        ),
        chunkSize: 2,
      );
      final stream = await store.read(SyncPath.parse('song.mp3'));
      expect(await stream.take(2).expand((chunk) => chunk).toList(), [
        1,
        2,
        1,
        2,
      ]);
      expect(channel.offsets, [0, 2]);
      expect(channel.handles, [null, 'read-1']);
      expect(channel.closed, ['read-1']);
    },
  );

  test('read closes the native handle at EOF', () async {
    final channel = _SequentialReadChannel()..eofAt = 2;
    final store = BrokerLocalObjectStore(
      channel: channel,
      root: MutableBrokerRootPort(
        const BrokerRoot(token: 'opaque', generation: 'g1'),
      ),
      chunkSize: 2,
    );
    final stream = await store.read(SyncPath.parse('song.mp3'));
    expect(await stream.expand((chunk) => chunk).toList(), [1, 2, 1, 2]);
    expect(channel.closed, ['read-1']);
  });

  test('read is chunked through the injected broker port', () async {
    final channel = _FakeChannel();
    final roots = MutableBrokerRootPort(
      const BrokerRoot(token: 'opaque', generation: 'g1'),
    );
    final store = BrokerLocalObjectStore(
      channel: channel,
      root: roots,
      chunkSize: 2,
    );

    final stream = await store.read(SyncPath.parse('album/song.mp3'));
    expect(await stream.expand((chunk) => chunk).toList(), [1, 2]);
    expect(channel.calls, ['localReadChunk']);
  });

  test('root generation changes are carried to every broker call', () async {
    final channel = _FakeChannel();
    final roots = MutableBrokerRootPort(
      const BrokerRoot(token: 'opaque', generation: 'g1'),
    );
    final store = BrokerLocalObjectStore(channel: channel, root: roots);
    channel.onCall = (method, arguments) {
      if (method == 'localReadChunk') {
        expect(arguments['token'], 'opaque');
        expect(arguments['generation'], 'g1');
        roots.current = const BrokerRoot(token: 'new-token', generation: 'g2');
      }
    };
    final stream = await store.read(SyncPath.parse('song.mp3'));
    await expectLater(stream.toList(), throwsA(isA<NeedsRescan>()));
    expect(channel.calls, ['localReadChunk']);
  });

  test(
    'stage rejects a broker hash mismatch and retains opaque handle semantics',
    () async {
      final channel = _FakeChannel()
        ..finishHash =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final store = BrokerLocalObjectStore(
        channel: channel,
        root: MutableBrokerRootPort(
          const BrokerRoot(token: 'opaque', generation: 'g1'),
        ),
      );
      await expectLater(
        store.stage(
          SyncPath.parse('song.mp3'),
          Stream<List<int>>.value(const [1, 2]),
          expectedSha256: _hash,
        ),
        throwsA(isA<BrokerError>()),
      );
    },
  );

  test('invalid absolute and traversal paths are rejected before IPC', () {
    expect(() => SyncPath.parse('../song.mp3'), throwsFormatException);
    expect(() => SyncPath.parse('C:/song.mp3'), throwsFormatException);
  });

  test('verify propagates a failed staged hash or length check', () async {
    final channel = _FakeChannel()..failVerification = true;
    final store = BrokerLocalObjectStore(
      channel: channel,
      root: MutableBrokerRootPort(
        const BrokerRoot(token: 'opaque', generation: 'g1'),
      ),
    );
    final verified = await store.verifyStaged(
      const StagedObject(key: 'stage-key', sha256: _hash, length: 2),
      expectedSha256: _hash,
      expectedLength: 2,
    );
    expect(verified, isFalse);
  });

  test(
    'delete derives a stable recovery key for retryable operations',
    () async {
      final channel = _FakeChannel();
      final store = BrokerLocalObjectStore(
        channel: channel,
        root: MutableBrokerRootPort(
          const BrokerRoot(token: 'opaque', generation: 'g1'),
        ),
      );
      final path = SyncPath.parse('album/song.mp3');
      final condition = LocalMatchSha256(_hash);
      await store.delete(
        path,
        condition: condition,
        operationId: 'operation-a',
      );
      await store.delete(
        path,
        condition: condition,
        operationId: 'operation-a',
      );
      await store.delete(
        path,
        condition: condition,
        operationId: 'operation-b',
      );

      expect(channel.deleteArguments, hasLength(3));
      expect(
        channel.deleteArguments[0]['backupKey'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(
        channel.deleteArguments[1]['backupKey'],
        channel.deleteArguments[0]['backupKey'],
      );
      expect(
        channel.deleteArguments[2]['backupKey'],
        isNot(channel.deleteArguments[0]['backupKey']),
      );
      expect(channel.deleteArguments[0]['condition'], <String, Object?>{
        'type': 'matchSha256',
        'sha256': _hash,
      });
    },
  );

  test(
    'failed journal marker does not hide the latest staged recovery',
    () async {
      final channel = _FakeChannel();
      final store = BrokerLocalObjectStore(
        channel: channel,
        root: MutableBrokerRootPort(
          const BrokerRoot(token: 'opaque', generation: 'g1'),
        ),
      );
      final path = SyncPath.parse('song.mp3');
      final entry = SyncEntry.file(
        id: 'song',
        path: path,
        size: 2,
        modifiedAtUtc: DateTime.utc(2026, 1, 1),
        sha256: _hash,
        revision: 1,
        favorite: const FavoriteStamp(value: false, lamport: 0, deviceId: ''),
      );
      final operation = SyncOperation(
        id: 'operation',
        kind: SyncOperationKind.putRemoteToLocal,
        path: SyncPath.parse('song.mp3'),
        planId: 'plan',
        generation: 'g1',
        localCondition: LocalCreateOnly(),
        source: entry,
      );
      final plan = SyncPlan(
        planId: 'plan',
        generation: 'g1',
        operations: [operation],
        deletionsSuppressed: false,
      );
      final staged = JournalRecord(
        planId: 'plan',
        generation: 'g1',
        operationId: 'operation',
        path: path,
        state: JournalState.staged,
        atUtc: DateTime.utc(2026, 1, 1),
        stagingKey: 'stage-key',
        sha256: _hash,
        length: 2,
      );
      await store.recoverPendingPlan(
        const SyncRoot('opaque', generation: 'g1'),
        plan,
        journal: [
          staged,
          JournalRecord(
            planId: 'plan',
            generation: 'g1',
            operationId: 'operation',
            path: path,
            state: JournalState.failed,
            atUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
          ),
        ],
      );
      expect(channel.calls, contains('localCommitStaged'));
    },
  );
}

final class _SequentialReadChannel implements BrokerMethodChannel {
  final offsets = <int>[];
  final handles = <Object?>[];
  final closed = <String>[];
  int? eofAt;
  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    final args = (arguments as Map).cast<String, Object?>();
    if (method == 'localCloseRead') {
      closed.add(args['readHandle'] as String);
      return {'status': 'ok'} as T;
    }
    expect(method, 'localReadChunk');
    final offset = args['offset'] as int;
    offsets.add(offset);
    handles.add(args['readHandle']);
    return {
      'status': 'ok',
      'bytes': Uint8List.fromList([1, 2]),
      'nextOffset': offset + 2,
      'readHandle': 'read-1',
      'eof': offset == eofAt,
    } as T;
  }
}
