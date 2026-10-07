import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synctune/infrastructure/network/windows_winrt_http_adapter.dart';
import 'package:synctune/infrastructure/platform/broker_local_object_store.dart';

void main() {
  late Directory staging;
  late _FakeWebDavChannel channel;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('synctune-http-test-');
    channel = _FakeWebDavChannel(
      databasePath: '${staging.path}${Platform.pathSeparator}database.sqlite',
    );
  });

  tearDown(() async {
    await staging.delete(recursive: true);
  });

  test(
    'passes DAV method, If-Match, status, headers, and bounded body chunks',
    () async {
      final adapter = WindowsWinRtHttpAdapter(channel: channel);
      final response = await adapter.fetch(
        RequestOptions(
          path: 'https://dav.example.test/music/song.mp3',
          method: 'PUT',
          headers: const <String, Object?>{
            'If-Match': '"etag-1"',
            'Content-Type': 'audio/mpeg',
          },
        ),
        Stream<Uint8List>.fromIterable(<Uint8List>[
          Uint8List.fromList(<int>[1, 2]),
          Uint8List.fromList(<int>[3, 4, 5]),
        ]),
        null,
      );

      expect(channel.openMethod, 'PUT');
      expect(channel.openHeaders['If-Match'], '"etag-1"');
      expect(channel.openBody, <int>[1, 2, 3, 4, 5]);
      expect(response.statusCode, 207);
      expect(response.headers['etag'], <String>['"etag-2"']);
      expect(await response.stream.expand((chunk) => chunk).toList(), <int>[
        9,
        8,
        7,
      ]);
      expect(channel.closedIds, contains(channel.requestId));
    },
  );

  test('Dio contributes DAV content headers and redirect policy', () async {
    final dio = Dio(
      BaseOptions(
        followRedirects: false,
        maxRedirects: 0,
        responseType: ResponseType.plain,
      ),
    )..httpClientAdapter = WindowsWinRtHttpAdapter(channel: channel);
    await dio.requestUri<String>(
      Uri.parse('https://dav.example.test/music/'),
      data: '<d:propfind xmlns:d="DAV:"><d:prop/></d:propfind>',
      options: Options(
        method: 'PROPFIND',
        headers: const <String, Object?>{
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
        },
        validateStatus: (_) => true,
      ),
    );
    expect(channel.openMethod, 'PROPFIND');
    expect(channel.openBody, isNotEmpty);
    expect(channel.openHeaders['Depth'], '0');
    expect(
      channel.openHeaders['Content-Type'],
      'application/xml; charset=utf-8',
    );
    expect(
      channel.openHeaders.keys.any(
        (key) => key.toLowerCase() == 'content-length',
      ),
      isTrue,
    );
  });

  test(
    'root staging supplies Content-Length to the native DAV request',
    () async {
      final roots = MutableBrokerRootPort(
        const BrokerRoot(token: 'token-1', generation: 'generation-1'),
      );
      final adapter = WindowsWinRtHttpAdapter(channel: channel, root: roots);
      final response = await adapter.fetch(
        RequestOptions(
          path: 'https://dav.example.test/music/song.mp3',
          method: 'PUT',
        ),
        Stream<Uint8List>.value(Uint8List.fromList(<int>[1, 2, 3, 4, 5])),
        null,
      );

      expect(channel.openHeaders['Content-Length'], '5');
      expect(channel.openBody, <int>[1, 2, 3, 4, 5]);
      await response.stream.drain<void>();
    },
  );

  test('cancels an open timeout', () async {
    final pending = _FakeWebDavChannel(
      databasePath: '${staging.path}${Platform.pathSeparator}database.sqlite',
      holdOpen: true,
    );
    final adapter = WindowsWinRtHttpAdapter(channel: pending);
    await expectLater(
      adapter.fetch(
        RequestOptions(
          path: 'https://dav.example.test/music',
          connectTimeout: const Duration(milliseconds: 10),
        ),
        null,
        null,
      ),
      throwsA(isA<DioException>()),
    );
    expect(pending.cancelledIds, contains(pending.requestId));
  });

  test('cancels a source that stops producing and removes its stage', () async {
    final source = StreamController<Uint8List>();
    final cancellation = Completer<void>();
    final adapter = WindowsWinRtHttpAdapter(channel: channel);
    final request = adapter.fetch(
      RequestOptions(path: 'https://dav.example.test/music/song.mp3'),
      source.stream,
      cancellation.future,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    cancellation.complete();

    await expectLater(
      request.timeout(const Duration(seconds: 2)),
      throwsA(isA<DioException>()),
    );
    await source.close();
    expect(
      staging.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.part'),
      ),
      isEmpty,
    );
  });

  test('cleans a failed upload staging file', () async {
    final failedUpload = _FakeWebDavChannel(
      databasePath: '${staging.path}${Platform.pathSeparator}database.sqlite',
    );
    final uploadAdapter = WindowsWinRtHttpAdapter(channel: failedUpload);
    final source = Stream<Uint8List>.multi((controller) {
      controller.add(Uint8List.fromList(<int>[1, 2, 3]));
      controller.addError(StateError('source stopped'));
      controller.close();
    });
    await expectLater(
      uploadAdapter.fetch(
        RequestOptions(path: 'https://dav.example.test/music/song.mp3'),
        source,
        null,
      ),
      throwsA(isA<StateError>()),
    );
    expect(failedUpload.openCalled, isFalse);
    expect(
      staging.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.part'),
      ),
      isEmpty,
    );
  });
}

final class _FakeWebDavChannel implements BrokerMethodChannel {
  _FakeWebDavChannel({required this.databasePath, this.holdOpen = false});

  final String databasePath;
  final bool holdOpen;
  final _openCompleter = Completer<Object?>();
  String? requestId;
  String? openMethod;
  Map<String, Object?> openHeaders = <String, Object?>{};
  List<int> openBody = <int>[];
  bool openCalled = false;
  int reads = 0;
  final Set<String> closedIds = <String>{};
  final Set<String> cancelledIds = <String>{};
  final Map<String, List<int>> stagedBodies = <String, List<int>>{};

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    final map = arguments is Map ? arguments.cast<Object?, Object?>() : null;
    final value = switch (method) {
      'privateDatabasePath' => databasePath,
      'webdavOpen' => await _open(map),
      'webdavRead' => _read(map),
      'webdavClose' => _close(map, false),
      'webdavCancel' => _close(map, true),
      'localStageBegin' => _stageBegin(map),
      'localStageWrite' => _stageWrite(map),
      'localStageFinish' => _stageFinish(map),
      'webdavCleanupBody' => null,
      _ => throw StateError('Unexpected method $method'),
    };
    return value as T?;
  }

  Future<Object?> _open(Map<Object?, Object?>? map) async {
    openCalled = true;
    requestId = map?['id']?.toString();
    openMethod = map?['method']?.toString();
    final rawHeaders = map?['headers'];
    if (rawHeaders is Map) {
      openHeaders = rawHeaders.cast<String, Object?>();
    }
    final bodyPath = map?['bodyPath']?.toString();
    if (bodyPath != null) openBody = await File(bodyPath).readAsBytes();
    final bodyKey = map?['bodyKey']?.toString();
    if (bodyKey != null) openBody = stagedBodies[bodyKey] ?? <int>[];
    if (holdOpen) return _openCompleter.future;
    return <String, Object?>{
      'id': requestId,
      'statusCode': 207,
      'statusMessage': 'Multi-Status',
      'headers': <String, String>{'ETag': '"etag-2"'},
    };
  }

  Object _stageBegin(Map<Object?, Object?>? map) {
    final key = map?['path']?.toString() ?? 'stage';
    stagedBodies[key] = <int>[];
    return <String, Object?>{'status': 'ok', 'key': key};
  }

  Object _stageWrite(Map<Object?, Object?>? map) {
    final key = map?['key']?.toString() ?? '';
    final offset = map?['offset'] as int? ?? -1;
    final bytes = map?['bytes'] as Uint8List? ?? Uint8List(0);
    final body = stagedBodies[key];
    if (body == null || offset != body.length) {
      throw StateError('non-contiguous fake staging write');
    }
    body.addAll(bytes);
    return <String, Object?>{'status': 'ok', 'nextOffset': body.length};
  }

  Object _stageFinish(Map<Object?, Object?>? map) => <String, Object?>{
    'status': 'ok',
    'key': map?['key'],
    'sha256': map?['expectedSha256'],
  };

  Object _read(Map<Object?, Object?>? map) {
    reads++;
    if (reads == 1) {
      return <String, Object?>{
        'bytes': Uint8List.fromList(<int>[9, 8, 7]),
        'eof': false,
      };
    }
    return <String, Object?>{'bytes': Uint8List(0), 'eof': true};
  }

  Object? _close(Map<Object?, Object?>? map, bool cancel) {
    final id = map?['id']?.toString();
    if (id != null) {
      closedIds.add(id);
      if (cancel) cancelledIds.add(id);
    }
    return null;
  }
}
