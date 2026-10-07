import 'dart:async';
import 'dart:typed_data';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import 'package:synctune/data/webdav_repository.dart';
import 'package:synctune/infrastructure/runtime/foreground_sync_runtime.dart';

final class _RequestRecord {
  _RequestRecord(this.options, this.bytes);
  final RequestOptions options;
  final List<int> bytes;
}

final class _QueueAdapter implements HttpClientAdapter {
  _QueueAdapter(this.responses);
  final List<ResponseBody> responses;
  final requests = <_RequestRecord>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(
      _RequestRecord(
        options,
        stream == null
            ? <int>[]
            : await stream.expand((chunk) => chunk).toList(),
      ),
    );
    return responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _ok([String etag = '"new"']) => ResponseBody.fromString(
  '',
  201,
  headers: {
    'etag': [etag],
  },
);

final class _BlockingAdapter implements HttpClientAdapter {
  final started = Completer<void>();
  final response = Completer<ResponseBody>();
  Future<void>? cancellation;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    cancellation = cancelFuture;
    started.complete();
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}

final class _StalledBodyAdapter implements HttpClientAdapter {
  final body = StreamController<Uint8List>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async => ResponseBody(
    body.stream,
    200,
    headers: {
      'etag': ['"body"'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  test('async cancellation interrupts a request before its response', () async {
    final adapter = _BlockingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final token = RuntimeCancellationSource();
    addTearDown(() async {
      await token.dispose();
      dio.close(force: true);
    });
    final repository = WebDavRepository(
      dio: dio,
      baseUri: Uri.parse('https://dav.test/dav/music/'),
    );
    final observed = repository
        .headEtag(SyncPath.parse('song.mp3'), token: token)
        .then<Object?>((value) => value, onError: (Object error) => error);
    await adapter.started.future;
    token.cancel();
    expect(adapter.cancellation, isNotNull);
    await adapter.cancellation!.timeout(const Duration(seconds: 1));
    expect(
      await observed.timeout(const Duration(seconds: 1)),
      isA<SyncCancelled>(),
    );
    adapter.response.complete(
      ResponseBody.fromString(
        '',
        200,
        headers: {
          'etag': ['"body"'],
        },
      ),
    );
  });

  test(
    'async cancellation interrupts a response body waiting for bytes',
    () async {
      final adapter = _StalledBodyAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final token = RuntimeCancellationSource();
      addTearDown(() async {
        await adapter.body.close();
        await token.dispose();
        dio.close(force: true);
      });
      final repository = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://dav.test/dav/music/'),
      );
      final stream = await repository.read(
        SyncPath.parse('song.mp3'),
        token: token,
      );
      final observed = stream.toList().then<Object?>(
        (value) => value,
        onError: (Object error) => error,
      );
      token.cancel();
      expect(
        await observed.timeout(const Duration(seconds: 1)),
        isA<SyncCancelled>(),
      );
    },
  );

  test('WebDAV requires HTTPS and emits explicit CAS headers', () {
    expect(
      () =>
          WebDavRepository(dio: Dio(), baseUri: Uri.parse('http://lan.test/')),
      throwsA(isA<WebDavCompatibilityError>()),
    );
    expect(WebDavRepository.conditionalHeaders(const CreateOnly()), {
      'If-None-Match': '*',
    });
    expect(WebDavRepository.conditionalHeaders(MatchEtag('"strong"')), {
      'If-Match': '"strong"',
    });
  });

  test(
    'nested writes create parent collections and verify 405 idempotence',
    () async {
      final adapter = _QueueAdapter([
        _ok(), // album MKCOL
        _ok(), // disc MKCOL
        _ok(), // content PUT
        _ok(), // .synctune MKCOL
        _ok(), // entries MKCOL
        _ok(), // descriptor PUT
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final repository = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://dav.test/music/'),
      );
      final nested = SyncPath.parse('album/disc/song.mp3');
      final entry = SyncEntry.file(
        id: 'song-id',
        path: nested,
        size: 3,
        modifiedAtUtc: DateTime.utc(2026, 10, 6),
        sha256:
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      await repository.put(
        nested,
        Stream.value(utf8.encode('abc')),
        entry: entry,
        condition: const CreateOnly(),
        metadataCondition: const CreateOnly(),
      );
      expect(adapter.requests.map((request) => request.options.method), [
        'MKCOL',
        'MKCOL',
        'PUT',
        'MKCOL',
        'MKCOL',
        'PUT',
      ]);
      expect(adapter.requests[0].options.uri.path, endsWith('/album'));
      expect(adapter.requests[1].options.uri.path, endsWith('/album/disc'));

      final collectionXml = '''
      <D:multistatus xmlns:D="DAV:"><D:response>
        <D:href>/music/album</D:href><D:propstat><D:prop>
          <D:getetag>"album"</D:getetag><D:resourcetype><D:collection/></D:resourcetype>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
      </D:response></D:multistatus>
    ''';
      final verifyAdapter = _QueueAdapter([
        ResponseBody.fromString('', 405),
        ResponseBody.fromString(collectionXml, 207),
      ]);
      final verifyDio = Dio()..httpClientAdapter = verifyAdapter;
      addTearDown(verifyDio.close);
      final verifyRepository = WebDavRepository(
        dio: verifyDio,
        baseUri: Uri.parse('https://dav.test/music/'),
      );
      await verifyRepository.mkcol(SyncPath.parse('album'));
      expect(verifyAdapter.requests.map((request) => request.options.method), [
        'MKCOL',
        'PROPFIND',
      ]);
    },
  );

  test(
    'PROPFIND parser preserves metadata and leaves weak validators unused',
    () {
      const xml = '''
      <D:multistatus xmlns:D="DAV:">
        <D:response>
          <D:href>/dav/music/album/song.mp3</D:href>
          <D:propstat>
            <D:prop>
              <D:getetag>"abc"</D:getetag>
              <D:getcontentlength>42</D:getcontentlength>
              <D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
    ''';
      final resources = WebDavRepository.parsePropfind(
        xml,
        baseUri: Uri.parse('https://dav.test/dav/music/'),
      );
      expect(resources, hasLength(1));
      expect(resources.single.path.value, 'album/song.mp3');
      expect(resources.single.etag, '"abc"');
      expect(resources.single.size, 42);
      expect(
        WebDavRepository.parsePropfind(xml.replaceFirst('"abc"', 'W/"weak"'))
            .single
            .etag,
        isEmpty,
      );
    },
  );

  test(
    'PROPFIND accepts collection optional fields and literal percent paths',
    () {
      const xml = '''
      <D:multistatus xmlns:D="DAV:">
        <D:response>
          <D:href>/dav/music/</D:href>
          <D:propstat>
            <D:prop><D:getetag>"root"</D:getetag><D:resourcetype><D:collection/></D:resourcetype></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
          <D:propstat>
            <D:prop><D:getcontentlength>0</D:getcontentlength></D:prop>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:propstat>
        </D:response>
        <D:response>
          <D:href>/dav/music/literal%252Fpercent.mp3</D:href>
          <D:propstat>
            <D:prop>
              <D:getetag>"file"</D:getetag>
              <D:getcontentlength>1</D:getcontentlength>
              <D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
    ''';
      final resources = WebDavRepository.parsePropfind(
        xml,
        baseUri: Uri.parse('https://dav.test/dav/music/'),
      );
      expect(resources, hasLength(1));
      expect(resources.single.isCollection, isFalse);
      expect(resources.single.path.value, 'literal%2Fpercent.mp3');
    },
  );

  test(
    'snapshot provider walks DAV collections and requires entry metadata',
    () async {
      final adapter = _QueueAdapter([
        ResponseBody.fromString('''
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/dav/music/album/</D:href><D:propstat><D:prop>
            <D:getetag>"album"</D:getetag><D:resourcetype><D:collection/></D:resourcetype>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>/dav/music/song.mp3</D:href><D:propstat><D:prop>
            <D:getetag>"song"</D:getetag><D:getcontentlength>3</D:getcontentlength>
            <D:getlastmodified>Tue, 06 Oct 2026 14:30:00 GMT</D:getlastmodified>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
      ''', 207),
        ResponseBody.fromString(
          '''
        <?xml version="1.0"?><entry xmlns="urn:synctune:v1" id="song-id"
          path="song.mp3" kind="file" size="3"
          modifiedAtUtc="2026-10-06T14:30:00Z" revision="2"
          favorite="false" favoriteLamport="0" favoriteDevice="device-a"
          sha256="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"/>
      ''',
          200,
          headers: {
            'etag': ['"entry-meta"'],
          },
        ),
        ResponseBody.fromString('', 404),
        ResponseBody.fromString('''
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>/dav/music/album/</D:href>
          <D:propstat><D:prop><D:getetag>"album"</D:getetag>
            <D:resourcetype><D:collection/></D:resourcetype>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
      ''', 207),
        ResponseBody.fromString('', 404),
      ]);
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final repository = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://dav.test/dav/music/'),
      );
      final snapshot = await WebDavRemoteSnapshotProvider(
        repository: repository,
      ).capture(const SyncRoot('music', generation: 'g1'));
      expect(snapshot.complete, isTrue);
      expect(snapshot.entries, hasLength(1));
      final object = snapshot.entries[SyncPath.parse('song.mp3')]!;
      expect(object.entry.id, 'song-id');
      expect(object.metadataEtag, '"entry-meta"');
      expect(object.favoriteEtag, isNull);
    },
  );

  test('delete persists a tombstone descriptor after content CAS', () async {
    final adapter = _QueueAdapter([
      ResponseBody.fromString('', 204),
      _ok(),
      _ok(),
      _ok('"tombstone"'),
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final repository = WebDavRepository(
      dio: dio,
      baseUri: Uri.parse('https://dav.test/dav/music/'),
    );
    final path = SyncPath.parse('song.mp3');
    await repository.delete(
      path,
      condition: MatchEtag('"content-old"'),
      tombstone: SyncEntry.tombstone(
        id: 'song-id',
        path: path,
        modifiedAtUtc: DateTime.utc(2026, 10, 6),
        revision: 3,
      ),
      metadataCondition: MatchEtag('"entry-old"'),
    );
    expect(adapter.requests, hasLength(4));
    expect(adapter.requests[0].options.method, 'DELETE');
    expect(adapter.requests[1].options.method, 'MKCOL');
    expect(adapter.requests[2].options.method, 'MKCOL');
    expect(adapter.requests[3].options.headers['If-Match'], '"entry-old"');
    expect(
      adapter.requests[3].options.uri.path,
      contains('/.synctune/entries/'),
    );
  });

  test(
    'delete validates tombstone CAS before changing remote content',
    () async {
      final adapter = _QueueAdapter(const []);
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final repository = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://dav.test/dav/music/'),
      );
      final path = SyncPath.parse('song.mp3');
      await expectLater(
        repository.delete(
          path,
          condition: MatchEtag('"content-old"'),
          tombstone: SyncEntry.tombstone(
            id: 'song-id',
            path: path,
            modifiedAtUtc: DateTime.utc(2026, 10, 6),
          ),
        ),
        throwsA(isA<WebDavCompatibilityError>()),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test('existing DAV files require explicit create-only adoption', () async {
    final adapter = _QueueAdapter([
      ResponseBody.fromString('''
        <D:multistatus xmlns:D="DAV:"><D:response>
          <D:href>/dav/music/song.mp3</D:href><D:propstat><D:prop>
            <D:getetag>"content"</D:getetag><D:getcontentlength>3</D:getcontentlength>
            <D:getlastmodified>Tue, 06 Oct 2026 14:30:00 GMT</D:getlastmodified>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response></D:multistatus>
      ''', 207),
      ResponseBody.fromBytes(
        utf8.encode('abc'),
        200,
        headers: {
          'etag': ['"content"'],
        },
      ),
      _ok(),
      _ok(),
      _ok('"metadata"'),
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final repository = WebDavRepository(
      dio: dio,
      baseUri: Uri.parse('https://dav.test/dav/music/'),
    );
    final path = SyncPath.parse('song.mp3');
    await repository.adoptExistingFile(
      SyncEntry.file(
        id: 'stable-id',
        path: path,
        size: 3,
        modifiedAtUtc: DateTime.utc(2026, 10, 6),
        sha256:
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      ),
    );
    expect(adapter.requests, hasLength(5));
    expect(adapter.requests[1].options.method, 'GET');
    expect(adapter.requests[1].options.headers['If-Match'], '"content"');
    expect(adapter.requests[2].options.method, 'MKCOL');
    expect(adapter.requests[3].options.method, 'MKCOL');
    expect(adapter.requests[4].options.headers['If-None-Match'], '*');
  });

  test('readWithEtag follows 301 and 302 redirects', () async {
    final adapter = _QueueAdapter([
      ResponseBody.fromString(
        '',
        301,
        headers: {
          'location': ['https://dav.test/dav/music/redirected.mp3'],
        },
      ),
      ResponseBody.fromBytes(
        utf8.encode('abc'),
        200,
        headers: {
          'etag': ['"content"'],
        },
      ),
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final repository = WebDavRepository(
      dio: dio,
      baseUri: Uri.parse('https://dav.test/dav/music/'),
    );
    final result = await repository.readWithEtag(SyncPath.parse('song.mp3'));
    expect(result, isNotNull);
    final bytes = await result!.stream.expand((c) => c).toList();
    expect(utf8.decode(bytes), 'abc');
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests[0].options.uri.path, endsWith('/song.mp3'));
    expect(adapter.requests[1].options.uri.path, endsWith('/redirected.mp3'));
  });

  test('headEtag follows 301 redirect', () async {
    final adapter = _QueueAdapter([
      ResponseBody.fromString(
        '',
        301,
        headers: {
          'location': ['https://dav.test/dav/music/redirected.mp3'],
        },
      ),
      ResponseBody.fromString(
        '',
        200,
        headers: {
          'etag': ['"etag-123"'],
        },
      ),
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final repository = WebDavRepository(
      dio: dio,
      baseUri: Uri.parse('https://dav.test/dav/music/'),
    );
    final etag = await repository.headEtag(SyncPath.parse('song.mp3'));
    expect(etag, '"etag-123"');
    expect(adapter.requests, hasLength(2));
  });

  test('propfind follows 301 redirect', () async {
    final adapter = _QueueAdapter([
      ResponseBody.fromString(
        '',
        301,
        headers: {
          'location': ['https://dav.test/dav/music/album/'],
        },
      ),
      ResponseBody.fromString('''
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/music/album/song.mp3</D:href>
            <D:propstat>
              <D:prop>
                <D:getetag>"song"</D:getetag>
                <D:getcontentlength>3</D:getcontentlength>
                <D:getlastmodified>Tue, 06 Oct 2026 14:30:00 GMT</D:getlastmodified>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
      ''', 207),
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final repository = WebDavRepository(
      dio: dio,
      baseUri: Uri.parse('https://dav.test/dav/music/'),
    );
    final resources = await repository.propfind(SyncPath.parse('album'));
    expect(resources, hasLength(1));
    expect(resources.single.path.value, 'album/song.mp3');
    expect(adapter.requests, hasLength(2));
  });
}
