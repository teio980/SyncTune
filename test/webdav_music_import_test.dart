import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/data/webdav_repository.dart';
import 'package:synctune/infrastructure/runtime/foreground_sync_runtime.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

const _root = SyncRoot('music', generation: 'g1');
const _hash =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  late _Dav adapter;
  late WebDavRemoteSnapshotProvider provider;
  setUp(() {
    adapter = _Dav();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    provider = WebDavRemoteSnapshotProvider(
      repository: WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://dav.test/dav/'),
      ),
    );
  });

  test('ordinary scan identifies unmanaged music without writing', () async {
    await expectLater(
      provider.capture(_root),
      throwsA(isA<RemoteMusicImportRequired>()),
    );
    expect(
      adapter.requests.every((r) => ['GET', 'PROPFIND'].contains(r.method)),
      isTrue,
    );
    expect(adapter.descriptors, isEmpty);
  });

  test(
    'explicit import creates identity and enables a complete snapshot',
    () async {
      await provider.importExistingMusic();
      final put = adapter.requests.where((r) => r.method == 'PUT').single;
      expect(put.uri.path, startsWith('/dav/.synctune/entries/'));
      expect(put.headers['If-None-Match'], '*');
      expect(adapter.requests.where((r) => r.method == 'DELETE'), isEmpty);
      expect(
        adapter.requests
            .where(
              (r) => r.method == 'GET' && r.uri.path == '/dav/album/song.mp3',
            )
            .every((r) => r.headers['If-Match'] == '"song"'),
        isTrue,
      );

      final snapshot = await provider.capture(_root);
      expect(snapshot.complete, isTrue);
      expect(snapshot.entries, hasLength(1));
      final entry = snapshot.entries.values.single.entry;
      expect(entry.id, startsWith('import-'));
      expect(entry.sha256, _hash);
      expect(entry.path.value, 'album/song.mp3');
      expect(entry.size, 3);
    },
  );

  test(
    'retry preserves an existing identity without another metadata write',
    () async {
      await provider.importExistingMusic();
      final descriptors = Map<String, String>.from(adapter.descriptors);
      adapter.requests.clear();
      await provider.importExistingMusic();
      expect(adapter.descriptors, descriptors);
      expect(
        adapter.requests.every((r) => ['GET', 'PROPFIND'].contains(r.method)),
        isTrue,
      );
    },
  );

  test('content ETag changes stop import before any write', () async {
    adapter.songEtag = '"changed"';
    await expectLater(
      provider.importExistingMusic(),
      throwsA(isA<NeedsRescan>()),
    );
    expect(adapter.descriptors, isEmpty);
    expect(adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test(
    'content changes during adoption verification stop metadata creation',
    () async {
      adapter.changeSecondRead = true;
      await expectLater(
        provider.importExistingMusic(),
        throwsA(isA<NeedsRescan>()),
      );
      expect(adapter.descriptors, isEmpty);
      expect(adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
    },
  );

  test('concurrent metadata creation fails CAS without overwriting', () async {
    adapter.rejectCreate = true;
    await expectLater(
      provider.importExistingMusic(),
      throwsA(isA<RemotePreconditionFailed>()),
    );
    expect(adapter.descriptors, isEmpty);
    expect(
      adapter.requests
          .where((r) => r.method == 'PUT')
          .single
          .headers['If-None-Match'],
      '*',
    );
  });

  test('cancelled import sends no requests', () async {
    final token = RuntimeCancellationSource()..cancel();
    addTearDown(token.dispose);
    await expectLater(
      provider.importExistingMusic(token: token),
      throwsA(isA<SyncCancelled>()),
    );
    expect(adapter.requests, isEmpty);
  });

  test('partial import retries only remaining files and preserves the first identity', () async {
    adapter.includeSecondSong = true;
    adapter.rejectSecondCreate = true;
    await expectLater(
      provider.importExistingMusic(),
      throwsA(isA<RemotePreconditionFailed>()),
    );
    expect(adapter.descriptors, hasLength(1));
    final first = Map<String, String>.from(adapter.descriptors);
    adapter.rejectSecondCreate = false;
    adapter.requests.clear();
    await provider.importExistingMusic();
    expect(adapter.descriptors, hasLength(2));
    expect(adapter.descriptors[first.keys.single], first.values.single);
    expect(adapter.requests.where((r) => r.method == 'PUT'), hasLength(1));
  });

  test('collections may omit ETag while files still require a strong ETag', () {
    final resources = WebDavRepository.parsePropfind(
      _multistatus([_collection('/dav/album/')]),
      baseUri: Uri.parse('https://dav.test/dav/'),
    );
    expect(resources.single.isCollection, isTrue);
    expect(resources.single.etag, isEmpty);
    expect(
      () => WebDavRepository.parsePropfind(
        _multistatus([_file('/dav/song.mp3', 3, 'W/"weak"')]),
        baseUri: Uri.parse('https://dav.test/dav/'),
      ),
      throwsA(isA<WebDavCompatibilityError>()),
    );
  });
}

String _response(String href, String props) =>
    '''
<D:response><D:href>$href</D:href><D:propstat><D:prop>$props</D:prop>
<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>''';
String _collection(String href) =>
    _response(href, '<D:resourcetype><D:collection/></D:resourcetype>');
String _file(String href, int length, String etag) => _response(href, '''
<D:getetag>$etag</D:getetag><D:getcontentlength>$length</D:getcontentlength>
<D:getlastmodified>Tue, 06 Oct 2026 14:30:00 GMT</D:getlastmodified>''');
String _multistatus(List<String> resources) =>
    '<D:multistatus xmlns:D="DAV:">${resources.join()}</D:multistatus>';

final class _Dav implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final descriptors = <String, String>{};
  final directories = <String>{'/dav/', '/dav/album/'};
  String songEtag = '"song"';
  bool changeSecondRead = false;
  bool rejectCreate = false;
  bool includeSecondSong = false;
  bool rejectSecondCreate = false;
  int songReads = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    if (options.method == 'MKCOL') {
      final directory = path.endsWith('/') ? path : '$path/';
      return ResponseBody.fromString(
        '',
        directories.add(directory) ? 201 : 405,
      );
    }
    if (options.method == 'PUT') {
      expect(path, startsWith('/dav/.synctune/entries/'));
      expect(options.headers['If-None-Match'], '*');
      final bytes = await body!.expand((c) => c).toList();
      if (rejectCreate ||
          (rejectSecondCreate && descriptors.isNotEmpty) ||
          descriptors.containsKey(path)) {
        return ResponseBody.fromString('', 412);
      }
      descriptors[path] = utf8.decode(bytes);
      return ResponseBody.fromString(
        '',
        201,
        headers: {
          'etag': ['"meta"'],
        },
      );
    }
    if (options.method == 'GET') {
      if (path == '/dav/album/song.mp3' || path == '/dav/album/second.mp3') {
        songReads++;
        return ResponseBody.fromString(
          changeSecondRead && songReads > 1 ? 'xyz' : 'abc',
          200,
          headers: {
            'etag': [songEtag],
          },
        );
      }
      final descriptor = descriptors[path];
      return ResponseBody.fromString(
        descriptor ?? '',
        descriptor == null ? 404 : 200,
        headers: descriptor == null
            ? {}
            : {
                'etag': ['"meta"'],
              },
      );
    }
    if (options.method == 'PROPFIND') {
      if (path == '/dav/album/song.mp3' || path == '/dav/album/second.mp3') {
        return ResponseBody.fromString(
          _multistatus([_file(path, 3, '"song"')]),
          207,
        );
      }
      final directory = path.endsWith('/') ? path : '$path/';
      if (!directories.contains(directory)) {
        return ResponseBody.fromString('', 404);
      }
      final resources = <String>[_collection(directory)];
      for (final child in directories) {
        if (child != directory &&
            child.startsWith(directory) &&
            !child
                .substring(directory.length, child.length - 1)
                .contains('/')) {
          resources.add(_collection(child));
        }
      }
      if (directory == '/dav/album/') {
        resources.add(_file('/dav/album/song.mp3', 3, '"song"'));
        if (includeSecondSong) {
          resources.add(_file('/dav/album/second.mp3', 3, '"song"'));
        }
      }
      for (final entry in descriptors.entries) {
        if (entry.key.startsWith(directory) &&
            !entry.key.substring(directory.length).contains('/')) {
          resources.add(
            _file(
              Uri(path: entry.key).toString(),
              utf8.encode(entry.value).length,
              '"meta"',
            ),
          );
        }
      }
      return ResponseBody.fromString(_multistatus(resources), 207);
    }
    throw StateError('Unexpected ${options.method} $path');
  }

  @override
  void close({bool force = false}) {}
}
