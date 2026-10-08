import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/sync/local_store.dart';
import 'package:synctune/sync/state_store.dart';
import 'package:synctune/sync/sync_engine.dart';
import 'package:synctune/sync/sync_model.dart';
import 'package:synctune/sync/webdav_client.dart';

void main() {
  late Directory directory;
  late MemoryWebDav server;
  late SyncSettings settings;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('synctune-engine-');
    server = await MemoryWebDav.start();
    settings = SyncSettings(
      localRoot: '${directory.path}${Platform.pathSeparator}music',
      localRootId: 'test-root',
      localGeneration: 'test-generation',
      serverUrl: server.url,
      remoteRoot: '',
      username: 'user',
      language: 'en',
    );
    await Directory(settings.localRoot).create(recursive: true);
  });

  tearDown(() async {
    await server.close();
    await directory.delete(recursive: true);
  });

  test(
    'concurrent edits retain both versions at matching relative paths',
    () async {
      final path = File(
        '${settings.localRoot}${Platform.pathSeparator}song.mp3',
      );
      await path.writeAsString('shared');
      server.set('song.mp3', utf8.encode('shared'));
      final state = SqliteStateStore(
        '${directory.path}${Platform.pathSeparator}state.sqlite',
      );
      await state.open();
      addTearDown(state.close);
      final engine = SyncEngine(
        localStore: FileLocalStore(settings.localRoot),
        webDav: WebDavClient(),
        stateStore: state,
      );

      await _run(engine, settings);
      await path.writeAsString('phone edit');
      server.set('song.mp3', utf8.encode('cloud edit'));
      await _run(engine, settings);

      expect(await path.readAsString(), 'cloud edit');
      final localFiles = await FileLocalStore(settings.localRoot)
          .scan(CancellationToken());
      final conflict = localFiles.files.singleWhere(
        (file) => file.path != SyncPath.parse('song.mp3'),
      );
      expect(conflict.path.value, contains('SyncTune conflict'));
      expect(
        await File(
          '${settings.localRoot}${Platform.pathSeparator}'
          '${conflict.path.value.replaceAll('/', Platform.pathSeparator)}',
        ).readAsString(),
        'phone edit',
      );
      expect(server.read('song.mp3'), utf8.encode('cloud edit'));
      expect(server.read(conflict.path.value), utf8.encode('phone edit'));
      expect(state.loadPending(), isEmpty);
    },
  );

  test(
    'a local commit interrupted after publication is reconciled on next start',
    () async {
      server.set('song.mp3', utf8.encode('cloud song'));
      final state = SqliteStateStore(
        '${directory.path}${Platform.pathSeparator}state.sqlite',
      );
      await state.open();
      addTearDown(state.close);
      final fileStore = FileLocalStore(settings.localRoot);
      final engine = SyncEngine(
        localStore: _CrashAfterCommitOnce(fileStore),
        webDav: WebDavClient(),
        stateStore: state,
      );

      await expectLater(_run(engine, settings), throwsA(isA<SyncFailure>()));
      expect(state.loadPending(), hasLength(1));
      expect(
        await File('${settings.localRoot}${Platform.pathSeparator}song.mp3')
            .readAsString(),
        'cloud song',
      );

      await _run(engine, settings);

      expect(state.loadPending(), isEmpty);
      expect(
        state.loadBaseline()[SyncPath.parse('song.mp3')]?.sha256,
        hashBytes(utf8.encode('cloud song')),
      );
    },
  );
}

Future<void> _run(SyncEngine engine, SyncSettings settings) => engine.run(
  settings,
  secret: 'test-secret',
  cancellation: CancellationToken(),
);

final class _CrashAfterCommitOnce implements LocalStore {
  _CrashAfterCommitOnce(this.delegate);
  final FileLocalStore delegate;
  bool _shouldCrash = true;

  @override
  String stageKey(String id) => delegate.stageKey(id);
  @override
  String backupKey(String id) => delegate.backupKey(id);
  @override
  Future<int?> modifiedMs(SyncPath path) => delegate.modifiedMs(path);
  @override
  Future<String?> stageHash(String id, CancellationToken token) =>
      delegate.stageHash(id, token);
  @override
  Future<Stream<List<int>>> readStage(String id, CancellationToken token) =>
      delegate.readStage(id, token);
  @override
  Future<String?> backupHash(String id, CancellationToken token) =>
      delegate.backupHash(id, token);
  @override
  Future<SyncScanResult> scan(
    CancellationToken token, {
    SyncByteProgress? onBytes,
    SyncFileProgress? onFile,
  }) => delegate.scan(token, onBytes: onBytes, onFile: onFile);
  @override
  Future<Stream<List<int>>> read(SyncPath path, CancellationToken token) =>
      delegate.read(path, token);
  @override
  Future<String?> hash(SyncPath path, CancellationToken token) =>
      delegate.hash(path, token);
  @override
  Future<String> stage(
    String id,
    Stream<List<int>> source,
    String expected,
    CancellationToken token, {
    SyncByteProgress? onBytes,
    SyncPath? path,
  }) =>
      delegate.stage(id, source, expected, token, onBytes: onBytes, path: path);
  @override
  Future<void> commit(
    SyncPath path,
    String stageKey,
    String backupKey,
    String expected,
    String? previous,
    CancellationToken token,
  ) async {
    await delegate.commit(path, stageKey, backupKey, expected, previous, token);
    if (_shouldCrash) {
      _shouldCrash = false;
      throw const SyncFailure(
        'Simulated interruption after local publication.',
      );
    }
  }

  @override
  Future<void> deleteVerified(
    SyncPath path,
    String backupKey,
    String expected,
    CancellationToken token,
  ) => delegate.deleteVerified(path, backupKey, expected, token);
  @override
  Future<void> restore(
    SyncPath path,
    String backupKey,
    String expected,
    CancellationToken token,
  ) => delegate.restore(path, backupKey, expected, token);
  @override
  Future<bool> canResumeCommit(
    SyncPath path,
    String operationId,
    String expected,
    String? previous,
    CancellationToken token,
  ) => delegate.canResumeCommit(path, operationId, expected, previous, token);
  @override
  Future<void> cleanup(PendingOperation operation, CancellationToken token) =>
      delegate.cleanup(operation, token);
}

final class MemoryWebDav {
  MemoryWebDav._(this._server);
  final HttpServer _server;
  final Map<String, List<int>> _files = <String, List<int>>{};
  final Set<String> _directories = <String>{'/dav'};
  int _revision = 0;

  String get url => 'http://127.0.0.1:${_server.port}/dav';

  static Future<MemoryWebDav> start() async {
    final server = MemoryWebDav._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(server._handle);
    return server;
  }

  void set(String relative, List<int> bytes) {
    _files['/dav/$relative'] = List<int>.of(bytes);
    _revision++;
  }

  List<int>? read(String relative) => _files['/dav/$relative'];

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = _normalize(request.uri.path);
    final depth = request.headers.value('depth');
    if (request.method == 'MKCOL') {
      if (_directories.contains(path)) {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      } else if (!_directories.contains(_parent(path))) {
        request.response.statusCode = HttpStatus.conflict;
      } else {
        _directories.add(path);
        request.response.statusCode = HttpStatus.created;
      }
    } else if (request.method == 'PROPFIND') {
      if (_directories.contains(path) && depth == '1') {
        final children = <String>{
          ..._files.keys.where((item) => _parent(item) == path),
          ..._directories.where(
            (item) => item != path && _parent(item) == path,
          ),
        };
        _respondMultiStatus(request, <String>[path, ...children]);
      } else if (_files.containsKey(path) || _directories.contains(path)) {
        _respondMultiStatus(request, <String>[path]);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } else if (request.method == 'GET') {
      final body = _files[path];
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.headers.set(HttpHeaders.etagHeader, _etag(path));
        request.response.add(body);
      }
    } else if (request.method == 'PUT') {
      final current = _files[path];
      final ifMatch = request.headers.value(HttpHeaders.ifMatchHeader);
      final ifNoneMatch = request.headers.value(HttpHeaders.ifNoneMatchHeader);
      if ((ifMatch != null && (current == null || ifMatch != _etag(path))) ||
          (ifNoneMatch == '*' && current != null)) {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.preconditionFailed;
      } else {
        final bytes = await request.fold<List<int>>(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        );
        _files[path] = bytes;
        _revision++;
        request.response.statusCode = HttpStatus.created;
        request.response.headers.set(HttpHeaders.etagHeader, _etag(path));
      }
    } else if (request.method == 'DELETE') {
      final ifMatch = request.headers.value(HttpHeaders.ifMatchHeader);
      if (!_files.containsKey(path) ||
          (ifMatch != null && ifMatch != _etag(path))) {
        request.response.statusCode = HttpStatus.preconditionFailed;
      } else {
        _files.remove(path);
        _revision++;
        request.response.statusCode = HttpStatus.noContent;
      }
    } else {
      request.response.statusCode = HttpStatus.methodNotAllowed;
    }
    await request.response.close();
  }

  void _respondMultiStatus(HttpRequest request, List<String> paths) {
    request.response.statusCode = 207;
    final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">');
    for (final path in paths) {
      final directory = _directories.contains(path);
      final bytes = _files[path];
      final href = directory && path == '/dav' ? '/dav/' : path;
      xml.write('<d:response><d:href>$href</d:href><d:propstat><d:prop>');
      xml.write(
        directory
            ? '<d:resourcetype><d:collection/></d:resourcetype>'
            : '<d:resourcetype/>',
      );
      if (!directory && bytes != null) {
        xml.write('<d:getcontentlength>${bytes.length}</d:getcontentlength>');
        xml.write('<d:getetag>${_etag(path)}</d:getetag>');
      }
      xml.write(
        '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
      );
    }
    xml.write('</d:multistatus>');
    request.response.write(xml);
  }

  String _etag(String path) => '"${_revision}_${path.hashCode}"';
  String _normalize(String path) =>
      path.length > 1 ? path.replaceFirst(RegExp(r'/+$'), '') : path;
  String _parent(String path) => path.substring(0, path.lastIndexOf('/'));
}
