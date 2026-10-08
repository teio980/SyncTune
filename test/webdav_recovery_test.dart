import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/data/sync_tune_database.dart';
import 'package:synctune/data/webdav_repository.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';
import 'package:xml/xml.dart';

final class _DavFile {
  _DavFile(this.bytes, this.etag);
  final List<int> bytes;
  final String etag;
}

/// Strict in-memory DAV used by formal recovery tests. Parent collections are
/// absent initially and every conditional write receives a fresh strong ETag.
final class _StrictDav implements HttpClientAdapter {
  final files = <String, _DavFile>{};
  final collections = <String>{'/music'};
  void Function(RequestOptions options)? beforeFetch;
  int revision = 0;

  String key(Uri uri) {
    final parts = uri.pathSegments.toList();
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
    return '/${parts.join('/')}';
  }

  bool _parentExists(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 || collections.contains(path.substring(0, slash));
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    beforeFetch?.call(options);
    final path = key(options.uri);
    final old = files[path];
    switch (options.method) {
      case 'MKCOL':
        if (!_parentExists(path)) return ResponseBody.fromString('', 409);
        if (files.containsKey(path)) return ResponseBody.fromString('', 405);
        return ResponseBody.fromString(
          '',
          collections.add(path) ? 201 : 405,
          headers: {
            'etag': ['"collection-${++revision}"'],
          },
        );
      case 'PUT':
        if (!_parentExists(path)) return ResponseBody.fromString('', 409);
        final bytes = stream == null
            ? <int>[]
            : await stream.expand((chunk) => chunk).toList();
        if (options.headers['If-None-Match'] == '*' && old != null) {
          return ResponseBody.fromString('', 412);
        }
        if (options.headers['If-Match'] != null &&
            options.headers['If-Match'] != old?.etag) {
          return ResponseBody.fromString('', 412);
        }
        if (!options.headers.containsKey('If-Match') &&
            !options.headers.containsKey('If-None-Match')) {
          return ResponseBody.fromString('', 428);
        }
        final etag = '"revision-${++revision}"';
        files[path] = _DavFile(bytes, etag);
        return ResponseBody.fromString(
          '',
          old == null ? 201 : 204,
          headers: {
            'etag': [etag],
          },
        );
      case 'GET':
        if (old == null) return ResponseBody.fromString('', 404);
        return ResponseBody.fromBytes(
          old.bytes,
          200,
          headers: {
            'etag': [old.etag],
          },
        );
      case 'HEAD':
        return ResponseBody.fromString(
          '',
          old == null ? 404 : 200,
          headers: {
            if (old != null) 'etag': [old.etag],
          },
        );
      case 'DELETE':
        if (old == null || options.headers['If-Match'] != old.etag) {
          return ResponseBody.fromString('', 412);
        }
        files.remove(path);
        return ResponseBody.fromString('', 204);
      case 'PROPFIND':
        if (!collections.contains(path) && !files.containsKey(path)) {
          return ResponseBody.fromString('', 404);
        }
        final builder = XmlBuilder();
        builder.element(
          'd:multistatus',
          namespaceUris: {'d': 'DAV:'},
          nest: () {
            final members = <String>{path};
            for (final candidate in {...collections, ...files.keys}) {
              if (candidate.startsWith('$path/') &&
                  !candidate.substring(path.length + 1).contains('/')) {
                members.add(candidate);
              }
            }
            for (final member in members) {
              final collection = collections.contains(member);
              final file = files[member];
              final href = Uri(
                pathSegments: [
                  '',
                  ...member.substring(1).split('/'),
                  if (collection) '',
                ],
              ).toString();
              builder.element(
                'd:response',
                nest: () {
                  builder.element('d:href', nest: href);
                  builder.element(
                    'd:propstat',
                    nest: () {
                      builder.element(
                        'd:prop',
                        nest: () {
                          builder.element(
                            'd:resourcetype',
                            nest: () {
                              if (collection) {
                                builder.element('d:collection');
                              }
                            },
                          );
                          builder.element(
                            'd:getetag',
                            nest: file?.etag ?? '"collection"',
                          );
                          builder.element(
                            'd:getcontentlength',
                            nest: '${file?.bytes.length ?? 0}',
                          );
                          builder.element(
                            'd:getlastmodified',
                            nest: 'Tue, 06 Oct 2026 14:30:00 GMT',
                          );
                        },
                      );
                      builder.element('d:status', nest: 'HTTP/1.1 200 OK');
                    },
                  );
                },
              );
            }
          },
        );
        return ResponseBody.fromString(
          builder.buildDocument().toXmlString(),
          207,
        );
      default:
        return ResponseBody.fromString('', 405);
    }
  }

  @override
  void close({bool force = false}) {}
}

final class _FormalLocal implements LocalObjectStore, LocalSnapshotProvider {
  final files = <SyncPath, List<int>>{};
  final entries = <SyncPath, SyncEntry>{};
  final stages = <String, List<int>>{};
  int next = 0;

  void seed(SyncEntry entry, String content) {
    entries[entry.path] = entry;
    files[entry.path] = utf8.encode(content);
  }

  @override
  Future<SyncSnapshot> capture(
    SyncRoot root, {
    CancellationToken token = const NeverCancelled(),
  }) async => SyncSnapshot(
    deviceId: 'formal-local',
    capturedAtUtc: DateTime.utc(2026, 10, 7),
    entries: entries.values,
    generation: root.generation,
  );

  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) async => Stream.value(files[path]!);

  @override
  Future<StagedObject> stage(
    SyncPath path,
    Stream<List<int>> content, {
    required String expectedSha256,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final bytes = await content.expand((chunk) => chunk).toList();
    final key = 'stage-${++next}';
    stages[key] = bytes;
    return StagedObject(
      key: key,
      sha256: sha256.convert(bytes).toString(),
      length: bytes.length,
    );
  }

  @override
  Future<Stream<List<int>>> openStaged(
    StagedObject staged, {
    CancellationToken token = const NeverCancelled(),
  }) async => Stream.value(stages[staged.key]!);

  @override
  Future<bool> verifyStaged(
    StagedObject staged, {
    required String expectedSha256,
    required int expectedLength,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final bytes = stages[staged.key];
    return bytes != null &&
        bytes.length == expectedLength &&
        sha256.convert(bytes).toString() == expectedSha256;
  }

  @override
  Future<void> commitStaged(
    SyncPath path,
    StagedObject staged, {
    required SyncEntry entry,
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final current = entries[path];
    final matches = condition is LocalCreateOnly
        ? current == null
        : condition is LocalMatchSha256 && current?.sha256 == condition.sha256;
    if (!matches) throw const NeedsRescan('formal local CAS failed');
    files[path] = List.of(stages[staged.key]!);
    entries[path] = entry;
  }

  @override
  Future<void> delete(
    SyncPath path, {
    required LocalCondition condition,
    SyncEntry? tombstone,
    String? operationId,
    CancellationToken token = const NeverCancelled(),
  }) async {
    if (condition is! LocalMatchSha256 ||
        entries[path]?.sha256 != condition.sha256) {
      throw const NeedsRescan('formal local delete CAS failed');
    }
    if (tombstone != null) {
      entries[path] = tombstone;
    } else {
      entries.remove(path);
    }
    files.remove(path);
  }

  @override
  Future<void> saveTombstone(
    SyncPath path,
    SyncEntry tombstone, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    entries[path] = tombstone;
    files.remove(path);
  }

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    entries[path] = entries[path]!.copyWith(favorite: stamp);
  }
}

const _root = SyncRoot('formal-root', generation: 'formal-generation');
final _path = SyncPath.parse('song.mp3');
final _when = DateTime.utc(2026, 10, 7);

SyncEntry _file(String value, {SyncPath? path}) => SyncEntry.file(
  id: 'stable-id',
  path: path ?? _path,
  size: utf8.encode(value).length,
  modifiedAtUtc: _when,
  sha256: sha256.convert(utf8.encode(value)).toString(),
);

Future<SyncRunResult> _run(
  SyncTuneDatabase db,
  _FormalLocal local,
  WebDavRepository remote,
  String planId,
) => const SyncCoordinator().run(
  _root,
  planId: planId,
  localSnapshots: local,
  remoteSnapshots: WebDavRemoteSnapshotProvider(repository: remote),
  baseline: db,
  plans: db,
  local: local,
  remote: remote,
  journal: db,
);

void main() {
  test(
    'ordinary cloud music imports, downloads, and confirms the baseline',
    () async {
      final server = _StrictDav();
      server.collections.add('/music/album');
      const contentPath = '/music/album/歌曲.mp3';
      server.files[contentPath] = _DavFile(utf8.encode('abc'), '"original"');
      final writes = <String>[];
      server.beforeFetch = (options) {
        if (options.method == 'PUT' || options.method == 'DELETE') {
          writes.add('${options.method} ${server.key(options.uri)}');
        }
      };
      final dio = Dio()..httpClientAdapter = server;
      final remote = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://formal.invalid/music/'),
      );
      final db = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await db.closeStore();
        dio.close(force: true);
      });
      final local = _FormalLocal();
      await expectLater(
        _run(db, local, remote, 'before-import'),
        throwsA(isA<RemoteMusicImportRequired>()),
      );
      expect(writes, isEmpty);
      await WebDavRemoteSnapshotProvider(repository: remote)
          .importExistingMusic();
      final first = await _run(db, local, remote, 'after-import');
      first.requireConfirmed();
      final path = SyncPath.parse('album/歌曲.mp3');
      expect(utf8.decode(local.files[path]!), 'abc');
      expect(local.entries[path]!.id, startsWith('import-'));
      expect(
        (await db.load(_root))!.entries[path]!.id,
        local.entries[path]!.id,
      );
      expect(writes, hasLength(1));
      expect(writes.single, startsWith('PUT /music/.synctune/entries/'));
      expect(server.files[contentPath]!.etag, '"original"');
      final second = await _run(db, local, remote, 'second-sync');
      second.requireConfirmed();
      expect(second.plan.operations, isEmpty);

      // Now test local rename:
      local.files.remove(path);
      local.entries.remove(path);
      final newPath = SyncPath.parse('album/《絕區零》橘福福EP食通萬物 修心修身 .mp3');
      local.seed(_file('abc', path: newPath), 'abc');
      final third = await _run(db, local, remote, 'third-sync-rename');
      third.requireConfirmed();
      expect(third.baselineConfirmed, isTrue);

      // Now test: server has the tombstone, but local lost it:
      local.entries.remove(path);
      final fourth = await _run(db, local, remote, 'fourth-sync-tombstone');
      fourth.requireConfirmed();
      expect(fourth.baselineConfirmed, isTrue);
    },
  );

  test(
    'formal ordinary upload recovery proves bytes and latest descriptor CAS',
    () async {
      final server = _StrictDav();
      final dio = Dio()..httpClientAdapter = server;
      final remote = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://formal.invalid/music/'),
      );
      final db = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await db.closeStore();
        dio.close(force: true);
      });
      await remote.put(
        _path,
        Stream.value(utf8.encode('abc')),
        entry: _file('abc'),
        condition: const CreateOnly(),
        metadataCondition: const CreateOnly(),
      );
      final local = _FormalLocal()..seed(_file('xyz'), 'xyz');
      await db.saveConfirmed(
        _root,
        SyncSnapshot(
          deviceId: 'formal-local',
          capturedAtUtc: _when,
          entries: [_file('abc')],
          generation: _root.generation,
        ),
        planId: 'formal-baseline',
      );
      var raced = false;
      server.beforeFetch = (options) {
        if (!raced &&
            options.method == 'PUT' &&
            server.key(options.uri) ==
                '/music/.synctune/entries/song.mp3.xml') {
          raced = true;
          final old = server.files['/music/.synctune/entries/song.mp3.xml']!;
          server.files['/music/.synctune/entries/song.mp3.xml'] = _DavFile(
            old.bytes,
            '"formal-descriptor-race"',
          );
        }
      };
      await expectLater(
        _run(db, local, remote, 'formal-interrupted'),
        throwsA(isA<NeedsRescan>()),
      );
      server.beforeFetch = null;
      final result = await _run(db, local, remote, 'formal-resume');
      result.requireConfirmed();
      expect(utf8.decode(server.files['/music/song.mp3']!.bytes), 'xyz');
    },
  );

  test(
    'formal recovery preserves a newer inline favorite and converges',
    () async {
      final server = _StrictDav();
      final dio = Dio()..httpClientAdapter = server;
      final remote = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://formal.invalid/music/'),
      );
      final db = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await db.closeStore();
        dio.close(force: true);
      });
      await remote.put(
        _path,
        Stream.value(utf8.encode('abc')),
        entry: _file('abc'),
        condition: const CreateOnly(),
        metadataCondition: const CreateOnly(),
      );
      final local = _FormalLocal()..seed(_file('xyz'), 'xyz');
      await db.saveConfirmed(
        _root,
        SyncSnapshot(
          deviceId: 'formal-local',
          capturedAtUtc: _when,
          entries: [_file('abc')],
          generation: _root.generation,
        ),
        planId: 'formal-favorite-baseline',
      );
      var raced = false;
      server.beforeFetch = (options) {
        if (!raced &&
            options.method == 'PUT' &&
            server.key(options.uri) ==
                '/music/.synctune/entries/song.mp3.xml') {
          raced = true;
          final old = server.files['/music/.synctune/entries/song.mp3.xml']!;
          server.files['/music/.synctune/entries/song.mp3.xml'] = _DavFile(
            old.bytes,
            '"formal-favorite-race"',
          );
        }
      };
      await expectLater(
        _run(db, local, remote, 'formal-favorite-gap'),
        throwsA(isA<NeedsRescan>()),
      );
      server.beforeFetch = null;
      final old = server.files['/music/.synctune/entries/song.mp3.xml']!;
      final updated = utf8
          .decode(old.bytes)
          .replaceAll('favorite="false"', 'favorite="true"')
          .replaceAll('favoriteLamport="0"', 'favoriteLamport="101"')
          .replaceAll('favoriteDevice=""', 'favoriteDevice="other-device"');
      server.files['/music/.synctune/entries/song.mp3.xml'] = _DavFile(
        utf8.encode(updated),
        '"formal-newer-favorite"',
      );
      SyncRunResult? result;
      for (var attempt = 0; attempt < 3; attempt++) {
        result = await _run(
          db,
          local,
          remote,
          'formal-favorite-resume-$attempt',
        );
        if (result.baselineConfirmed) break;
      }
      result!.requireConfirmed();
      const expected = FavoriteStamp(
        value: true,
        lamport: 101,
        deviceId: 'other-device',
      );
      expect(local.entries[_path]!.favorite, expected);
      final snapshot = await WebDavRemoteSnapshotProvider(repository: remote)
          .capture(_root);
      expect(snapshot.entries[_path]!.entry.favorite, expected);
    },
  );

  for (final interference in ['bytes', 'descriptor']) {
    test('formal upload recovery stops on changed $interference', () async {
      final server = _StrictDav();
      final dio = Dio()..httpClientAdapter = server;
      final remote = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://formal.invalid/music/'),
      );
      final db = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await db.closeStore();
        dio.close(force: true);
      });
      await remote.put(
        _path,
        Stream.value(utf8.encode('abc')),
        entry: _file('abc'),
        condition: const CreateOnly(),
        metadataCondition: const CreateOnly(),
      );
      final local = _FormalLocal()..seed(_file('xyz'), 'xyz');
      await db.saveConfirmed(
        _root,
        SyncSnapshot(
          deviceId: 'formal-local',
          capturedAtUtc: _when,
          entries: [_file('abc')],
          generation: _root.generation,
        ),
        planId: 'formal-negative-baseline',
      );
      var raced = false;
      server.beforeFetch = (options) {
        if (!raced &&
            options.method == 'PUT' &&
            server.key(options.uri) ==
                '/music/.synctune/entries/song.mp3.xml') {
          raced = true;
          final old = server.files['/music/.synctune/entries/song.mp3.xml']!;
          server.files['/music/.synctune/entries/song.mp3.xml'] = _DavFile(
            old.bytes,
            '"formal-race"',
          );
        }
      };
      await expectLater(
        _run(db, local, remote, 'formal-negative-gap'),
        throwsA(isA<NeedsRescan>()),
      );
      server.beforeFetch = null;
      if (interference == 'bytes') {
        server.files['/music/song.mp3'] = _DavFile(
          utf8.encode('uvw'),
          '"formal-other-bytes"',
        );
      } else {
        final old = server.files['/music/.synctune/entries/song.mp3.xml']!;
        server.files['/music/.synctune/entries/song.mp3.xml'] = _DavFile(
          utf8.encode(
            utf8.decode(old.bytes).replaceAll('stable-id', 'other-id'),
          ),
          '"formal-other-descriptor"',
        );
      }
      final before = server.files['/music/.synctune/entries/song.mp3.xml']!;
      await expectLater(
        _run(db, local, remote, 'formal-negative-stop'),
        throwsA(isA<NeedsRescan>()),
      );
      final after = server.files['/music/.synctune/entries/song.mp3.xml']!;
      expect(after.bytes, before.bytes);
      expect(after.etag, before.etag);
    });
  }

  test(
    'formal nested upload rejects a file used as an occupied parent',
    () async {
      final server = _StrictDav();
      server.files['/music/album'] = _DavFile(<int>[1], '"occupied"');
      final dio = Dio()..httpClientAdapter = server;
      final remote = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://formal.invalid/music/'),
      );
      addTearDown(dio.close);
      final nested = SyncPath.parse('album/song.mp3');
      final entry = _file('abc', path: nested);
      await expectLater(
        remote.put(
          nested,
          Stream.value(utf8.encode('abc')),
          entry: entry,
          condition: const CreateOnly(),
          metadataCondition: const CreateOnly(),
        ),
        throwsA(isA<WebDavCompatibilityError>()),
      );
      expect(server.files.containsKey('/music/album/song.mp3'), isFalse);
    },
  );

  for (final mode in [
    'transport',
    'etag-only',
    'new-content',
    'new-descriptor',
  ]) {
    test('formal delete recovery: $mode', () async {
      final server = _StrictDav();
      final dio = Dio()..httpClientAdapter = server;
      final remote = WebDavRepository(
        dio: dio,
        baseUri: Uri.parse('https://formal.invalid/music/'),
      );
      final db = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await db.closeStore();
        dio.close(force: true);
      });
      await remote.put(
        _path,
        Stream.value(utf8.encode('abc')),
        entry: _file('abc'),
        condition: const CreateOnly(),
        metadataCondition: const CreateOnly(),
      );
      final tombstone = SyncEntry.tombstone(
        id: 'stable-id',
        path: _path,
        modifiedAtUtc: _when.add(const Duration(seconds: 1)),
        revision: 1,
      );
      final local = _FormalLocal()..entries[_path] = tombstone;
      await db.saveConfirmed(
        _root,
        SyncSnapshot(
          deviceId: 'formal-local',
          capturedAtUtc: _when,
          entries: [_file('abc')],
          generation: _root.generation,
        ),
        planId: 'formal-delete-baseline',
      );
      var injected = false;
      server.beforeFetch = (options) {
        if (!injected &&
            options.method == 'PUT' &&
            server.key(options.uri) ==
                '/music/.synctune/entries/song.mp3.xml') {
          injected = true;
          if (mode == 'etag-only') {
            final old = server.files['/music/.synctune/entries/song.mp3.xml']!;
            server.files['/music/.synctune/entries/song.mp3.xml'] = _DavFile(
              old.bytes,
              '"formal-new-etag"',
            );
          } else {
            throw StateError('formal metadata transport fault');
          }
        }
      };
      await expectLater(
        _run(db, local, remote, 'formal-delete-gap'),
        throwsA(isA<NeedsRescan>()),
      );
      expect(server.files.containsKey('/music/song.mp3'), isFalse);
      server.beforeFetch = null;
      if (mode == 'new-content') {
        server.files['/music/song.mp3'] = _DavFile(
          utf8.encode('uvw'),
          '"formal-new-content"',
        );
      } else if (mode == 'new-descriptor') {
        final old = server.files['/music/.synctune/entries/song.mp3.xml']!;
        server.files['/music/.synctune/entries/song.mp3.xml'] = _DavFile(
          utf8.encode(
            utf8.decode(old.bytes).replaceAll('stable-id', 'external-id'),
          ),
          '"formal-new-descriptor"',
        );
      }
      if (mode.startsWith('new-')) {
        await expectLater(
          _run(db, local, remote, 'formal-delete-stop'),
          throwsA(isA<NeedsRescan>()),
        );
      } else {
        final result = await _run(db, local, remote, 'formal-delete-resume');
        result.requireConfirmed();
      }
    });
  }

  for (final localPrimary in [true, false]) {
    for (final parentMarker in [true, false]) {
      test(
        'formal conflict descriptor recovery localPrimary=$localPrimary parentMarker=$parentMarker',
        () async {
          final server = _StrictDav();
          final dio = Dio()..httpClientAdapter = server;
          final remote = WebDavRepository(
            dio: dio,
            baseUri: Uri.parse('https://formal.invalid/music/'),
          );
          final db = SyncTuneDatabase(NativeDatabase.memory());
          addTearDown(() async {
            await db.closeStore();
            dio.close(force: true);
          });
          final localValue = localPrimary ? 'xyz' : 'abc';
          final remoteValue = localPrimary ? 'abc' : 'xyz';
          final baseline = _file('original');
          final local = _FormalLocal()..seed(_file(localValue), localValue);
          await remote.put(
            _path,
            Stream.value(utf8.encode(remoteValue)),
            entry: _file(remoteValue),
            condition: const CreateOnly(),
            metadataCondition: const CreateOnly(),
          );
          await db.saveConfirmed(
            _root,
            SyncSnapshot(
              deviceId: 'formal-local',
              capturedAtUtc: _when,
              entries: [baseline],
              generation: _root.generation,
            ),
            planId: 'formal-conflict-baseline',
          );
          var injected = false;
          server.beforeFetch = (options) {
            if (!injected &&
                options.method == 'PUT' &&
                server.key(options.uri).contains('.sync-conflict-') &&
                server.key(options.uri).contains('/.synctune/entries/')) {
              injected = true;
              throw StateError('formal conflict descriptor fault');
            }
          };
          await expectLater(
            _run(db, local, remote, 'formal-conflict-gap'),
            throwsA(isA<NeedsRescan>()),
          );
          expect(injected, isTrue);
          final pending = (await db.loadUnfinishedPlan(_root))!;
          if (!parentMarker) {
            for (final operation in pending.conflicts) {
              await db.customStatement(
                'DELETE FROM sync_journal WHERE operation_id = ?',
                [operation.id],
              );
            }
          }
          server.beforeFetch = null;
          final result = await _run(
            db,
            local,
            remote,
            'formal-conflict-resume',
          );
          result.requireConfirmed();
          expect(local.files.values.map(utf8.decode).toSet(), {'abc', 'xyz'});
          expect(local.entries.length, 2);
          final captured = await WebDavRemoteSnapshotProvider(
            repository: remote,
          ).capture(_root);
          expect(captured.entries.length, 2);
        },
      );
    }
  }
}
