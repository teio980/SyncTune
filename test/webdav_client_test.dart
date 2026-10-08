import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/sync/sync_model.dart';
import 'package:synctune/sync/webdav_client.dart';

void main() {
  late HttpServer server;
  late Directory cache;
  late SyncSettings settings;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    cache = await Directory.systemTemp.createTemp('synctune-webdav-');
    settings = SyncSettings(
      localRoot: cache.path,
      localRootId: 'local',
      localGeneration: 'generation',
      serverUrl: 'http://127.0.0.1:${server.port}/dav',
      remoteRoot: '',
      username: 'user',
      language: 'en',
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await cache.delete(recursive: true);
  });

  test(
    'unchanged strong ETag reuses the confirmed hash without downloading',
    () async {
      var getCount = 0;
      server.listen((request) async {
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(_listing(etag: '"v1"', length: 4));
        } else {
          getCount++;
          request.response.statusCode = HttpStatus.internalServerError;
        }
        await request.response.close();
      });
      final path = SyncPath.parse('song.mp3');
      final baseline = <SyncPath, BaselineEntry>{
        path: BaselineEntry(
          path: path,
          sha256: _hash('song'),
          localModifiedMs: 0,
          remoteEtag: '"v1"',
          remoteSize: 4,
        ),
      };

      final files = await WebDavClient().scan(
        settings,
        baseline,
        cache,
        CancellationToken(),
      );

      expect(getCount, 0);
      expect(files.files.single.sha256, _hash('song'));
      expect(files.files.single.etag, '"v1"');
    },
  );

  test(
    'weak ETag is hashed from file content and listing failures stop the scan',
    () async {
      var forbidden = false;
      var getCount = 0;
      server.listen((request) async {
        if (request.method == 'PROPFIND') {
          if (forbidden) {
            request.response.statusCode = HttpStatus.forbidden;
          } else {
            request.response.statusCode = 207;
            request.response.write(_listing(etag: 'W/"v1"', length: 4));
          }
        } else if (request.method == 'GET') {
          getCount++;
          request.response.headers.set(HttpHeaders.etagHeader, 'W/"v1"');
          request.response.write('song');
        }
        await request.response.close();
      });

      final client = WebDavClient();
      final files = await client.scan(
        settings,
        const <SyncPath, BaselineEntry>{},
        cache,
        CancellationToken(),
      );
      expect(getCount, 1);
      expect(files.files.single.sha256, _hash('song'));

      forbidden = true;
      await expectLater(
        client.scan(
          settings,
          const <SyncPath, BaselineEntry>{},
          cache,
          CancellationToken(),
        ),
        throwsA(
          isA<SyncFailure>().having(
            (error) => error.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
    },
  );

  test(
    'HTTP 412 on conditional replacement stops without an unconditional retry',
    () async {
      var putCount = 0;
      String? condition;
      server.listen((request) async {
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(_fileMetadata(etag: '"v1"', length: 3));
        } else if (request.method == 'GET') {
          request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
          request.response.write('old');
        } else if (request.method == 'PUT') {
          putCount++;
          condition = request.headers.value('if');
          expect(request.headers.value('if-match'), isNull);
          expect(request.headers.value('cache-control'), 'no-cache');
          expect(request.headers.value('pragma'), 'no-cache');
          await request.drain<void>();
          request.response.statusCode = 412;
        }
        await request.response.close();
      });
      final oldHash = _hash('old');
      final replacement = utf8.encode('new');

      await expectLater(
        WebDavClient().put(
          settings,
          SyncPath.parse('song.mp3'),
          Stream<List<int>>.value(replacement),
          replacement.length,
          oldHash,
          '"v1"',
          '${cache.path}${Platform.pathSeparator}song.backup',
          CancellationToken(),
        ),
        throwsA(
          isA<SyncFailure>().having(
            (error) => error.statusCode,
            'statusCode',
            412,
          ),
        ),
      );
      expect(putCount, 1);
      expect(condition, '<${settings.serverUrl}/song.mp3> (["v1"])');
    },
  );

  test('connection test is a read-only PROPFIND of the complete URL', () async {
    final existing = settings;
    settings = SyncSettings(
      localRoot: existing.localRoot,
      localRootId: existing.localRootId,
      localGeneration: existing.localGeneration,
      serverUrl: existing.serverUrl,
      remoteRoot: 'Music/synctune',
      username: existing.username,
      language: existing.language,
    );
    final methods = <String>[];
    final paths = <String>[];
    var depth = '';
    server.listen((request) async {
      methods.add(request.method);
      paths.add(request.uri.path);
      depth = request.headers.value('depth') ?? '';
      request.response.statusCode = 207;
      request.response.write(_folderMetadata(request.uri.path));
      await request.response.close();
    });

    await WebDavClient().testConnection(
      settings,
      secret: 'saved-secret',
      token: CancellationToken(),
    );

    expect(methods, <String>['PROPFIND']);
    expect(paths, <String>['/dav/Music/synctune/']);
    expect(depth, '0');
  });

  test('connection test reports redirects without following them', () async {
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/other');
      await request.response.close();
    });

    await expectLater(
      WebDavClient().testConnection(
        settings,
        secret: 'secret',
        token: CancellationToken(),
      ),
      throwsA(
        isA<SyncFailure>().having(
          (error) => error.statusCode,
          'statusCode',
          302,
        ),
      ),
    );
    expect(requests, 1);
  });
}

String _folderMetadata(String href) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>$href</d:href><d:propstat>
    <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat></d:response>
</d:multistatus>
''';

String _listing({required String etag, required int length}) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/</d:href><d:propstat>
    <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat></d:response>
  <d:response><d:href>/dav/song.mp3</d:href><d:propstat>
    <d:prop><d:resourcetype/><d:getcontentlength>$length</d:getcontentlength><d:getetag>$etag</d:getetag></d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat></d:response>
</d:multistatus>
''';

String _fileMetadata({required String etag, required int length}) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/song.mp3</d:href><d:propstat>
    <d:prop><d:resourcetype/><d:getcontentlength>$length</d:getcontentlength><d:getetag>$etag</d:getetag></d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat></d:response>
</d:multistatus>
''';

String _hash(String value) => hashBytes(utf8.encode(value));
