import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:synctune/sync/state_store.dart';
import 'package:synctune/sync/sync_model.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('synctune-state-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('fresh state creates scan checkpoints', () async {
    final path = '${directory.path}${Platform.pathSeparator}state.sqlite';
    final store = SqliteStateStore(path);
    await store.open();
    store.close();

    final database = sqlite3.open(path);
    try {
      final tables = database
          .select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
          )
          .map((row) => row['name'] as String)
          .toSet();
      expect(tables, <String>{
        'settings',
        'baseline',
        'pending_operations',
        'scan_checkpoint',
      });
    } finally {
      database.close();
    }
  });

  test(
    'a configuration identity change cannot discard pending recovery',
    () async {
      final store = SqliteStateStore(
        '${directory.path}${Platform.pathSeparator}state.sqlite',
      );
      await store.open();
      addTearDown(store.close);
      final path = SyncPath.parse('Album/song.mp3');
      store.begin(
        PendingOperation(
          id: '12345678-1234-1234-1234-123456789abc',
          path: path,
          kind: 'write',
          expectedLocalHash: List<String>.filled(64, 'a').join(),
          expectedRemoteHash: List<String>.filled(64, 'a').join(),
          expectedSize: 7,
          previousLocalHash: null,
          previousRemoteHash: null,
          previousRemoteEtag: null,
          sourcePath: path,
          sourceSide: 'local',
          localStage: '12345678-1234-1234-1234-123456789abc',
          localBackup: '12345678-1234-1234-1234-123456789abc',
          remoteBackup:
              '/.synctune-local-v2/12345678-1234-1234-1234-123456789abc',
        ),
      );

      expect(
        () => store.saveSettings(const <String, String>{
          'sync_identity': 'different account',
        }, identityChanged: true),
        throwsA(isA<SyncFailure>()),
      );
      expect(store.loadPending(), hasLength(1));
    },
  );

  test(
    'a configuration identity change invalidates scan checkpoints',
    () async {
      final store = SqliteStateStore(
        '${directory.path}${Platform.pathSeparator}state.sqlite',
      );
      await store.open();
      addTearDown(store.close);
      store.ensureIdentity('first configuration');
      store
          .scanCheckpoint(reuse: false)
          .recordLocal(
            SyncPath.parse('song.mp3'),
            sha256: List<String>.filled(64, 'a').join(),
            size: 12,
            modifiedMs: 1,
          );
      expect(store.scanCheckpointCount(), 1);

      store.ensureIdentity('second configuration');

      expect(store.scanCheckpointCount(), 0);
    },
  );

  test('existing v2 baselines migrate without losing their hashes', () async {
    final path = '${directory.path}/existing.sqlite';
    final old = sqlite3.open(path);
    old.execute(
      'CREATE TABLE baseline (relative_path TEXT PRIMARY KEY NOT NULL, sha256 TEXT NOT NULL, local_modified_ms INTEGER NOT NULL, remote_etag TEXT, remote_size INTEGER NOT NULL)',
    );
    final hash = 'a' * 64;
    old.execute('INSERT INTO baseline VALUES(?,?,?,?,?)', [
      'song.flac',
      hash,
      123,
      '"etag"',
      55,
    ]);
    old.close();
    final state = SqliteStateStore(path);
    await state.open();
    final entry = state.loadBaseline()[SyncPath.parse('song.flac')]!;
    expect(entry.sha256, hash);
    expect(entry.remoteSha256, hash);
    expect(entry.comparisonHash, isNull);
    expect(entry.remoteEtag, '"etag"');
    state.close();
    final reopened = SqliteStateStore(path);
    await reopened.open();
    expect(reopened.loadBaseline().length, 1);
    reopened.close();
  });

  test('legacy database tables are rejected without migration', () async {
    final path = '${directory.path}${Platform.pathSeparator}old.sqlite';
    final oldDatabase = sqlite3.open(path);
    oldDatabase.execute('CREATE TABLE favorites (id TEXT PRIMARY KEY)');
    oldDatabase.close();

    final store = SqliteStateStore(path);
    await expectLater(store.open(), throwsA(isA<SyncFailure>()));
  });
}
