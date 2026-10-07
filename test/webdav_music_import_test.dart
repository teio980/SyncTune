import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
  late WebDavRepository repository;
  setUp(() {
    adapter = _Dav();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    repository = WebDavRepository(
      dio: dio,
      baseUri: Uri.parse('https://dav.test/dav/'),
    );
    provider = WebDavRemoteSnapshotProvider(repository: repository);
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

  for (final mode in ['GET missing', 'PUT missing', 'all missing', 'weak']) {
    test('import and repeated snapshot work with $mode ETags', () async {
      adapter.omitGetEtags = mode == 'GET missing' || mode == 'all missing';
      adapter.omitPutEtags = mode == 'PUT missing' || mode == 'all missing';
      adapter.omitListingEtags = mode == 'all missing';
      adapter.weakEtags = mode == 'weak';
      await provider.importExistingMusic();
      final snapshot = await provider.capture(_root);
      expect(snapshot.complete, isTrue);
      expect(snapshot.entries.values.single.entry.sha256, _hash);
      final descriptors = Map<String, String>.from(adapter.descriptors);
      await provider.importExistingMusic();
      expect(adapter.descriptors, descriptors);
      expect(
        (await provider.capture(_root)).entries.values.single.entry.id,
        snapshot.entries.values.single.entry.id,
      );
      expect(
        adapter.requests.any(
          (r) => '${r.headers['If-Match']}'.contains('synctune-sha256'),
        ),
        isFalse,
      );
    });
  }

  void omitEtags() {
    adapter.omitGetEtags = true;
    adapter.omitPutEtags = true;
    adapter.omitListingEtags = true;
  }

  for (final direction in ['download', 'upload']) {
    test(
      'full coordinator $direction confirms sync without any ETags',
      () async {
        omitEtags();
        final phone = _MemoryPhone();
        if (direction == 'download') {
          await provider.importExistingMusic();
        } else {
          adapter.songData = null;
          final entry = SyncEntry.file(
            id: 'phone-song',
            path: SyncPath.parse('album/song.mp3'),
            size: 3,
            sha256: _hash,
            modifiedAtUtc: DateTime.utc(2026, 10, 7),
          );
          phone.entries[entry.path] = entry;
          phone.bytes[entry.path] = utf8.encode('abc');
        }
        Future<SyncRunResult> sync(String id) => const SyncCoordinator().run(
          _root,
          planId: id,
          localSnapshots: phone,
          remoteSnapshots: provider,
          baseline: phone,
          local: phone,
          remote: repository,
          journal: phone,
        );
        final first = await sync('first');
        first.requireConfirmed();
        expect(first.baselineConfirmed, isTrue);
        expect(phone.bytes.values.single, utf8.encode('abc'));
        expect(adapter.songData, 'abc');
        adapter.requests.clear();
        (await sync('second')).requireConfirmed();
        expect(
          adapter.requests.where((r) => ['PUT', 'DELETE'].contains(r.method)),
          isEmpty,
        );
      },
    );
  }

  test(
    'no-ETag updates validate prior bytes and verify the uploaded result',
    () async {
      omitEtags();
      await provider.importExistingMusic();
      final previous = (await provider.capture(_root)).entries.values.single;
      final next = SyncEntry.file(
        id: previous.entry.id,
        path: previous.entry.path,
        size: 3,
        modifiedAtUtc: previous.entry.modifiedAtUtc,
        sha256: sha256.convert(utf8.encode('xyz')).toString(),
        favorite: previous.entry.favorite,
      );
      adapter.requests.clear();
      await repository.put(
        next.path,
        Stream.value(utf8.encode('xyz')),
        entry: next,
        condition: MatchEtag(previous.etag!),
        metadataCondition: MatchEtag(previous.metadataEtag!),
      );
      expect(adapter.songData, 'xyz');
      expect(
        (await provider.capture(_root)).entries.values.single.entry.sha256,
        next.sha256,
      );
      expect(adapter.requests.where((r) => r.method == 'PUT'), hasLength(2));
      expect(
        adapter.requests
            .where((r) => r.method == 'PUT')
            .every((r) => !r.headers.containsKey('If-Match')),
        isTrue,
      );
    },
  );

  for (final changed in ['song', 'descriptor']) {
    test(
      'no-ETag $changed change stops upload before modifying the song',
      () async {
        omitEtags();
        await provider.importExistingMusic();
        final previous = (await provider.capture(_root)).entries.values.single;
        if (changed == 'song') {
          adapter.songData = 'xyz';
        } else {
          adapter.descriptors.updateAll((_, value) => '$value\n');
        }
        adapter.requests.clear();
        await expectLater(
          repository.put(
            previous.entry.path,
            Stream.value(utf8.encode('abc')),
            entry: previous.entry,
            condition: MatchEtag(previous.etag!),
            metadataCondition: MatchEtag(previous.metadataEtag!),
          ),
          throwsA(isA<RemotePreconditionFailed>()),
        );
        expect(adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
      },
    );
  }

  test(
    'no-ETag deletion checks bytes and persists a readable tombstone',
    () async {
      omitEtags();
      await provider.importExistingMusic();
      final previous = (await provider.capture(_root)).entries.values.single;
      await repository.delete(
        previous.entry.path,
        condition: MatchEtag(previous.etag!),
        metadataCondition: MatchEtag(previous.metadataEtag!),
        tombstone: SyncEntry.tombstone(
          id: previous.entry.id,
          path: previous.entry.path,
          modifiedAtUtc: DateTime.utc(2026, 10, 7),
        ),
      );
      expect(adapter.songData, isNull);
      expect(
        (await provider.capture(_root)).entries.values.single.entry.isDeleted,
        isTrue,
      );
    },
  );

  test('no-ETag favorites can be created and updated', () async {
    omitEtags();
    await provider.importExistingMusic();
    var song = (await provider.capture(_root)).entries.values.single;
    await repository.updateFavorite(
      song.entry.path,
      const FavoriteStamp(value: true, lamport: 1, deviceId: 'phone'),
      condition: const CreateOnly(),
    );
    song = (await provider.capture(_root)).entries.values.single;
    expect(song.entry.favorite.value, isTrue);
    await repository.updateFavorite(
      song.entry.path,
      const FavoriteStamp(value: false, lamport: 2, deviceId: 'phone'),
      condition: MatchEtag(song.favoriteEtag!),
    );
    expect(
      (await provider.capture(_root))
          .entries
          .values
          .single
          .entry
          .favorite
          .value,
      isFalse,
    );
  });

  test('missing PUT ETag does not hide a corrupt write', () async {
    omitEtags();
    adapter.corruptWrite = true;
    await expectLater(
      provider.importExistingMusic(),
      throwsA(isA<RemoteFileVerificationFailed>()),
    );
  });

  test(
    'explicit import creates identity and enables a complete snapshot',
    () async {
      await provider.importExistingMusic();
      final put = adapter.requests.where((r) => r.method == 'PUT').single;
      expect(put.uri.path, startsWith('/dav/.synctune/entries/'));
      expect(put.headers['If-None-Match'], '*');
      expect(adapter.requests.where((r) => r.method == 'DELETE'), isEmpty);
      expect(adapter.songReads, 1);
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

  test('content changes after hashing stop metadata creation', () async {
    adapter.changeOnRecheck = true;
    await expectLater(
      provider.importExistingMusic(),
      throwsA(isA<NeedsRescan>()),
    );
    expect(adapter.descriptors, isEmpty);
    expect(adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test(
    'downloads use the stored representation rather than a compressed ETag',
    () async {
      adapter.compressionVariant = true;
      await provider.importExistingMusic();
      final snapshot = await provider.capture(_root);
      expect(snapshot.complete, isTrue);
      expect(snapshot.entries.values.single.entry.sha256, _hash);
      expect(
        adapter.requests
            .where((r) => r.method == 'GET')
            .every((r) => r.headers['Accept-Encoding'] == 'identity'),
        isTrue,
      );
    },
  );

  test(
    'Chinese song names with spaces and brackets import and rescan',
    () async {
      const name =
          '陆虎 Lu Hu《雪落下的声音》【延禧攻略 Story of Yanxi Palace OST電視劇片尾曲】Of.mp3';
      adapter.songPath = '/dav/album/$name';
      await provider.importExistingMusic();
      final snapshot = await provider.capture(_root);
      expect(snapshot.entries.values.single.entry.path.value, 'album/$name');
      expect(snapshot.entries.values.single.entry.sha256, _hash);
      expect(adapter.descriptors, hasLength(1));
    },
  );

  test(
    'truncated song reports byte counts and creates no descriptor',
    () async {
      adapter.truncateSong = true;
      await expectLater(
        provider.importExistingMusic(),
        throwsA(
          isA<RemoteFileVerificationFailed>()
              .having((e) => e.mismatch, 'mismatch', RemoteFileMismatch.length)
              .having((e) => e.expected, 'expected', 3)
              .having((e) => e.actual, 'actual', 2),
        ),
      );
      expect(adapter.descriptors, isEmpty);
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

  test('missing or weak ETags leave validation to file checksums', () {
    final resources = WebDavRepository.parsePropfind(
      _multistatus([_collection('/dav/album/')]),
      baseUri: Uri.parse('https://dav.test/dav/'),
    );
    expect(resources.single.isCollection, isTrue);
    expect(resources.single.etag, isEmpty);
    expect(
      WebDavRepository.parsePropfind(
        _multistatus([_file('/dav/song.mp3', 3, 'W/"weak"')]),
        baseUri: Uri.parse('https://dav.test/dav/'),
      ).single.etag,
      isEmpty,
    );
  });

  test('repeated snapshot of unchanged files does not re-read song bytes', () async {
    await provider.importExistingMusic();
    final firstSnapshot = await provider.capture(_root);
    expect(firstSnapshot.complete, isTrue);
    final readsBefore = adapter.songReads;
    final secondSnapshot = await provider.capture(_root);
    expect(secondSnapshot.complete, isTrue);
    expect(adapter.songReads, readsBefore);
  });

  test('external deletion of cloud file is captured as tombstone', () async {
    await provider.importExistingMusic();
    final snapshot = await provider.capture(_root);
    expect(snapshot.entries.values.single.entry.isDeleted, isFalse);
    adapter.songData = null;
    final afterDelete = await provider.capture(_root);
    expect(afterDelete.entries.values.single.entry.isDeleted, isTrue);
  });

  test('external modification of cloud file updates entry with new hash', () async {
    await provider.importExistingMusic();
    final original = await provider.capture(_root);
    expect(original.entries.values.single.entry.sha256, _hash);
    adapter.songData = 'modified content';
    adapter.songEtag = '"modified"';
    final modified = await provider.capture(_root);
    expect(
      modified.entries.values.single.entry.sha256,
      sha256.convert(utf8.encode('modified content')).toString(),
    );
    expect(modified.entries.values.single.entry.size, 'modified content'.length);
  });

  test('uploading identical content skips audio PUT and updates descriptor', () async {
    await provider.importExistingMusic();
    final previous = (await provider.capture(_root)).entries.values.single;
    final next = SyncEntry.file(
      id: 'new-id-for-same-content',
      path: previous.entry.path,
      size: 3,
      modifiedAtUtc: previous.entry.modifiedAtUtc,
      sha256: _hash,
      favorite: previous.entry.favorite,
    );
    adapter.requests.clear();
    await repository.put(
      next.path,
      Stream.value(utf8.encode('abc')),
      entry: next,
      condition: MatchEtag(previous.etag!),
      metadataCondition: MatchEtag(previous.metadataEtag!),
    );
    expect(adapter.requests.where((r) => r.method == 'PUT'), hasLength(1));
    expect(adapter.descriptors.values.single, contains('new-id-for-same-content'));
  });
}

String _response(String href, String props) =>
    '''
<D:response><D:href>$href</D:href><D:propstat><D:prop>$props</D:prop>
<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>''';
String _href(String path) => path.split('/').map(Uri.encodeComponent).join('/');
String _collection(String href) =>
    _response(href, '<D:resourcetype><D:collection/></D:resourcetype>');
String _file(String href, int length, String etag) => _response(href, '''
<D:getetag>$etag</D:getetag><D:getcontentlength>$length</D:getcontentlength>
<D:getlastmodified>Tue, 06 Oct 2026 14:30:00 GMT</D:getlastmodified>''');
String _multistatus(List<String> resources) =>
    '<D:multistatus xmlns:D="DAV:">${resources.join()}</D:multistatus>';

final class _MemoryPhone
    implements
        LocalSnapshotProvider,
        LocalObjectStore,
        BaselineStore,
        JournalStore {
  final entries = <SyncPath, SyncEntry>{};
  final bytes = <SyncPath, List<int>>{};
  final staged = <String, List<int>>{};
  final records = <JournalRecord>[];
  SyncSnapshot? baseline;

  @override
  Future<SyncSnapshot> capture(
    SyncRoot root, {
    CancellationToken token = const NeverCancelled(),
  }) async => SyncSnapshot(
    deviceId: 'phone',
    capturedAtUtc: DateTime.now().toUtc(),
    entries: entries.values,
    generation: root.generation,
  );
  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) async => Stream.value(bytes[path]!);
  @override
  Future<StagedObject> stage(
    SyncPath path,
    Stream<List<int>> content, {
    required String expectedSha256,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final data = await content.expand((c) => c).toList();
    final hash = sha256.convert(data).toString();
    if (hash != expectedSha256) {
      throw const NeedsRescan('download checksum mismatch');
    }
    final key = '${staged.length}';
    staged[key] = data;
    return StagedObject(key: key, sha256: hash, length: data.length);
  }

  @override
  Future<Stream<List<int>>> openStaged(
    StagedObject object, {
    CancellationToken token = const NeverCancelled(),
  }) async => Stream.value(staged[object.key]!);
  @override
  Future<bool> verifyStaged(
    StagedObject object, {
    required String expectedSha256,
    required int expectedLength,
    CancellationToken token = const NeverCancelled(),
  }) async =>
      staged[object.key]?.length == expectedLength &&
      sha256.convert(staged[object.key]!).toString() == expectedSha256;
  @override
  Future<void> commitStaged(
    SyncPath path,
    StagedObject object, {
    required SyncEntry entry,
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) async {
    if ((condition is LocalCreateOnly && bytes.containsKey(path)) ||
        (condition is LocalMatchSha256 &&
            entries[path]?.sha256 != condition.sha256)) {
      throw const NeedsRescan('local file changed');
    }
    entries[path] = entry;
    bytes[path] = staged[object.key]!;
  }

  @override
  Future<void> delete(
    SyncPath path, {
    required LocalCondition condition,
    SyncEntry? tombstone,
    String? operationId,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final entry = entries[path]!;
    bytes.remove(path);
    entries[path] = tombstone ??
        SyncEntry.tombstone(
          id: entry.id,
          path: path,
          modifiedAtUtc: DateTime.now().toUtc(),
          favorite: entry.favorite,
        );
  }

  @override
  Future<void> saveTombstone(
    SyncPath path,
    SyncEntry tombstone, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    bytes.remove(path);
    entries[path] = tombstone;
  }

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    entries[path] = entries[path]!.copyWith(favorite: stamp);
  }

  @override
  Future<SyncSnapshot?> load(SyncRoot root) async => baseline;
  @override
  Future<void> saveConfirmed(
    SyncRoot root,
    SyncSnapshot snapshot, {
    required String planId,
  }) async {
    baseline = snapshot;
  }

  @override
  Future<void> append(JournalRecord record) async {
    records.add(record);
  }

  @override
  Future<List<JournalRecord>> recordsFor(
    String planId,
    String generation,
  ) async => records
      .where((r) => r.planId == planId && r.generation == generation)
      .toList();
}

final class _Dav implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final descriptors = <String, String>{};
  final directories = <String>{'/dav/', '/dav/album/'};
  String songEtag = '"song"';
  String songPath = '/dav/album/song.mp3';
  String? songData = 'abc';
  bool omitGetEtags = false;
  bool omitPutEtags = false;
  bool omitListingEtags = false;
  bool weakEtags = false;
  bool corruptWrite = false;
  bool changeOnRecheck = false;
  bool compressionVariant = false;
  bool truncateSong = false;
  bool rejectCreate = false;
  bool includeSecondSong = false;
  bool rejectSecondCreate = false;
  int songReads = 0;

  Map<String, List<String>> _headers(String etag, bool omit) => omit
      ? {}
      : {
          'etag': [weakEtags ? 'W/$etag' : etag],
        };
  String _listingTag(String etag) => omitListingEtags
      ? ''
      : weakEtags
      ? 'W/$etag'
      : etag;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = '/${options.uri.pathSegments.join('/')}';
    if (options.method == 'MKCOL') {
      final directory = path.endsWith('/') ? path : '$path/';
      return ResponseBody.fromString(
        '',
        directories.add(directory) ? 201 : 405,
      );
    }
    if (options.method == 'PUT') {
      final bytes = await body!.expand((c) => c).toList();
      final isSong = path == songPath;
      final existing = isSong ? songData : descriptors[path];
      if (rejectCreate ||
          (rejectSecondCreate && descriptors.isNotEmpty) ||
          (options.headers['If-None-Match'] == '*' && existing != null)) {
        return ResponseBody.fromString('', 412);
      }
      final data = corruptWrite ? 'corrupted' : utf8.decode(bytes);
      if (isSong) {
        songData = data;
      } else {
        descriptors[path] = data;
      }
      return ResponseBody.fromString(
        '',
        201,
        headers: _headers(isSong ? songEtag : '"meta"', omitPutEtags),
      );
    }
    if (options.method == 'GET') {
      if (path == songPath || path == '/dav/album/second.mp3') {
        songReads++;
        return ResponseBody.fromString(
          truncateSong ? 'ab' : songData ?? '',
          songData == null ? 404 : 200,
          headers: _headers(
            compressionVariant &&
                    options.headers['Accept-Encoding'] != 'identity'
                ? '"song-gzip"'
                : songEtag,
            omitGetEtags,
          ),
        );
      }
      final descriptor = descriptors[path];
      return ResponseBody.fromString(
        descriptor ?? '',
        descriptor == null ? 404 : 200,
        headers: descriptor == null ? {} : _headers('"meta"', omitGetEtags),
      );
    }
    if (options.method == 'PROPFIND') {
      if (path == songPath || path == '/dav/album/second.mp3') {
        return ResponseBody.fromString(
          _multistatus([
            _file(
              _href(path),
              songData?.length ?? 0,
              _listingTag(changeOnRecheck ? '"changed"' : '"song"'),
            ),
          ]),
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
        if (songData != null) {
          resources.add(
            _file(_href(songPath), songData!.length, _listingTag('"song"')),
          );
        }
        if (includeSecondSong) {
          resources.add(
            _file('/dav/album/second.mp3', 3, _listingTag('"song"')),
          );
        }
      }
      for (final entry in descriptors.entries) {
        if (entry.key.startsWith(directory) &&
            !entry.key.substring(directory.length).contains('/')) {
          resources.add(
            _file(
              _href(entry.key),
              utf8.encode(entry.value).length,
              _listingTag('"meta"'),
            ),
          );
        }
      }
      return ResponseBody.fromString(_multistatus(resources), 207);
    }
    if (options.method == 'HEAD') {
      final isSong = path == songPath;
      final data = isSong ? songData : descriptors[path];
      return ResponseBody.fromString(
        '',
        data == null ? 404 : 200,
        headers: _headers(isSong ? songEtag : '"meta"', omitGetEtags),
      );
    }
    if (options.method == 'DELETE') {
      if (path == songPath) {
        songData = null;
      } else {
        descriptors.remove(path);
      }
      return ResponseBody.fromString('', 204);
    }
    throw StateError('Unexpected ${options.method} $path');
  }

  @override
  void close({bool force = false}) {}
}
