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
      default:
        return <String, Object?>{} as T;
    }
  }
}

void main() {
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
}
