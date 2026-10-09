import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'sync_model.dart';

final class SqliteStateStore {
  SqliteStateStore(this.databasePath);

  final String databasePath;
  Database? _database;
  Database get _db =>
      _database ?? (throw StateError('State store is not open.'));

  Future<void> open() async {
    if (_database != null) return;
    await Directory(File(databasePath).parent.path).create(recursive: true);
    final db = sqlite3.open(databasePath);
    try {
      _validateUnmigratedDatabase(db);
    } catch (_) {
      db.close();
      rethrow;
    }
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('''CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL
    )''');
    db.execute('''CREATE TABLE IF NOT EXISTS baseline (
      relative_path TEXT PRIMARY KEY NOT NULL,
      sha256 TEXT NOT NULL,
      local_modified_ms INTEGER NOT NULL,
      remote_etag TEXT,
      remote_size INTEGER NOT NULL
    )''');
    db.execute('''CREATE TABLE IF NOT EXISTS pending_operations (
      operation_id TEXT PRIMARY KEY NOT NULL,
      relative_path TEXT NOT NULL,
      kind TEXT NOT NULL,
      expected_local_sha256 TEXT,
      expected_remote_sha256 TEXT,
      expected_size INTEGER NOT NULL DEFAULT 0,
      previous_local_sha256 TEXT,
      previous_remote_sha256 TEXT,
      previous_remote_etag TEXT,
      source_path TEXT,
      source_side TEXT,
      local_stage TEXT,
      local_backup TEXT,
      remote_backup TEXT,
      local_done INTEGER NOT NULL DEFAULT 0,
      remote_done INTEGER NOT NULL DEFAULT 0,
      complete INTEGER NOT NULL DEFAULT 0,
      needs_rescan INTEGER NOT NULL DEFAULT 0,
      created_at_ms INTEGER NOT NULL
    )''');
    db.execute('''CREATE TABLE IF NOT EXISTS scan_checkpoint (
      side TEXT NOT NULL CHECK (side IN ('local','remote')),
      relative_path TEXT NOT NULL,
      sha256 TEXT NOT NULL,
      size INTEGER NOT NULL,
      modified_ms INTEGER NOT NULL,
      etag TEXT,
      PRIMARY KEY (side, relative_path)
    )''');
    _database = db;
  }

  void _validateUnmigratedDatabase(Database db) {
    const expected = <String, Set<String>>{
      'settings': <String>{'key', 'value'},
      'baseline': <String>{
        'relative_path',
        'sha256',
        'local_modified_ms',
        'remote_etag',
        'remote_size',
      },
      'scan_checkpoint': <String>{
        'side',
        'relative_path',
        'sha256',
        'size',
        'modified_ms',
        'etag',
      },
      'pending_operations': <String>{
        'operation_id',
        'relative_path',
        'kind',
        'expected_local_sha256',
        'expected_remote_sha256',
        'expected_size',
        'previous_local_sha256',
        'previous_remote_sha256',
        'previous_remote_etag',
        'source_path',
        'source_side',
        'local_stage',
        'local_backup',
        'remote_backup',
        'local_done',
        'remote_done',
        'complete',
        'needs_rescan',
        'created_at_ms',
      },
    };
    final objects = db.select(
      "SELECT name,type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'",
    );
    for (final object in objects) {
      final name = object['name'] as String;
      final type = object['type'] as String;
      if (type != 'table' || !expected.containsKey(name)) {
        throw const SyncFailure(
          'This is not a new SyncTune state database. Choose a fresh version 2 database; old state is not migrated.',
        );
      }
      final columns = db
          .select('PRAGMA table_info($name)')
          .map((row) => row['name'] as String)
          .toSet();
      if (columns.length != expected[name]!.length ||
          !columns.containsAll(expected[name]!)) {
        throw const SyncFailure(
          'This is not a new SyncTune state database. Choose a fresh version 2 database; old state is not migrated.',
        );
      }
    }
  }

  void close() {
    _database?.close();
    _database = null;
  }

  Map<String, String> loadSettings() => <String, String>{
    for (final row in _db.select('SELECT key, value FROM settings'))
      row['key'] as String: row['value'] as String,
  };

  bool ensureIdentity(String identity) {
    final previous = loadSettings()['sync_identity'];
    if (previous == identity) return false;
    _db.execute('BEGIN IMMEDIATE');
    try {
      final pending = _db.select(
        'SELECT operation_id FROM pending_operations LIMIT 1',
      );
      if (pending.isNotEmpty) {
        throw const SyncFailure(
          'Recover the previous sync before changing folders or the WebDAV account.',
        );
      }
      _db.execute('DELETE FROM baseline');
      _db.execute('DELETE FROM scan_checkpoint');
      _db.execute(
        'INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        <Object?>['sync_identity', identity],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return true;
  }

  void saveSettings(
    Map<String, String> values, {
    required bool identityChanged,
  }) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final pending = _db.select(
        'SELECT operation_id FROM pending_operations LIMIT 1',
      );
      if (pending.isNotEmpty && identityChanged) {
        throw const SyncFailure(
          'Finish recovery for the previous configuration before changing the sync folder or account.',
        );
      }
      if (identityChanged) {
        _db.execute('DELETE FROM baseline');
        _db.execute('DELETE FROM scan_checkpoint');
      }
      for (final entry in values.entries) {
        _db.execute(
          'INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
          <Object?>[entry.key, entry.value],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Opens the persisted scan checkpoint. With [reuse] false, hashes are only
  /// recorded; the caller reads every file itself.
  ScanCheckpoint scanCheckpoint({required bool reuse}) =>
      _SqliteScanCheckpoint(this, reuse: reuse);

  void clearScanCheckpoint() => _db.execute('DELETE FROM scan_checkpoint');

  int scanCheckpointCount() =>
      _db.select('SELECT COUNT(*) AS n FROM scan_checkpoint').single['n']
          as int;

  Map<SyncPath, BaselineEntry> loadBaseline() {
    final result = <SyncPath, BaselineEntry>{};
    for (final row in _db.select(
      'SELECT relative_path,sha256,local_modified_ms,remote_etag,remote_size FROM baseline',
    )) {
      final path = SyncPath.parse(row['relative_path'] as String);
      result[path] = BaselineEntry(
        path: path,
        sha256: row['sha256'] as String,
        localModifiedMs: row['local_modified_ms'] as int,
        remoteEtag: row['remote_etag'] as String?,
        remoteSize: row['remote_size'] as int,
      );
    }
    return result;
  }

  List<PendingOperation> loadPending() {
    return <PendingOperation>[
      for (final row in _db.select(
        'SELECT * FROM pending_operations ORDER BY created_at_ms, operation_id',
      ))
        PendingOperation(
          id: row['operation_id'] as String,
          path: SyncPath.parse(row['relative_path'] as String),
          kind: row['kind'] as String,
          expectedLocalHash: row['expected_local_sha256'] as String?,
          expectedRemoteHash: row['expected_remote_sha256'] as String?,
          expectedSize: row['expected_size'] as int,
          previousLocalHash: row['previous_local_sha256'] as String?,
          previousRemoteHash: row['previous_remote_sha256'] as String?,
          previousRemoteEtag: row['previous_remote_etag'] as String?,
          sourcePath: row['source_path'] == null
              ? null
              : SyncPath.parse(row['source_path'] as String),
          sourceSide: row['source_side'] as String?,
          localStage: row['local_stage'] as String?,
          localBackup: row['local_backup'] as String?,
          remoteBackup: row['remote_backup'] as String?,
          localDone: (row['local_done'] as int) != 0,
          remoteDone: (row['remote_done'] as int) != 0,
          complete: (row['complete'] as int) != 0,
          needsRescan: (row['needs_rescan'] as int) != 0,
        ),
    ];
  }

  void begin(PendingOperation operation) {
    _db.execute(
      '''INSERT INTO pending_operations(
      operation_id,relative_path,kind,expected_local_sha256,expected_remote_sha256,expected_size,
      previous_local_sha256,previous_remote_sha256,previous_remote_etag,source_path,source_side,local_stage,local_backup,remote_backup,
      local_done,remote_done,complete,needs_rescan,created_at_ms
    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(operation_id) DO NOTHING''',
      <Object?>[
        operation.id,
        operation.path.value,
        operation.kind,
        operation.expectedLocalHash,
        operation.expectedRemoteHash,
        operation.expectedSize,
        operation.previousLocalHash,
        operation.previousRemoteHash,
        operation.previousRemoteEtag,
        operation.sourcePath?.value,
        operation.sourceSide,
        operation.localStage,
        operation.localBackup,
        operation.remoteBackup,
        operation.localDone ? 1 : 0,
        operation.remoteDone ? 1 : 0,
        operation.complete ? 1 : 0,
        operation.needsRescan ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    final existing = loadPending()
        .where((item) => item.id == operation.id)
        .firstOrNull;
    if (existing == null ||
        existing.path != operation.path ||
        existing.kind != operation.kind ||
        existing.expectedLocalHash != operation.expectedLocalHash ||
        existing.expectedRemoteHash != operation.expectedRemoteHash ||
        existing.expectedSize != operation.expectedSize ||
        existing.previousLocalHash != operation.previousLocalHash ||
        existing.previousRemoteHash != operation.previousRemoteHash ||
        existing.previousRemoteEtag != operation.previousRemoteEtag ||
        existing.sourcePath != operation.sourcePath ||
        existing.sourceSide != operation.sourceSide ||
        existing.localStage != operation.localStage ||
        existing.localBackup != operation.localBackup ||
        existing.remoteBackup != operation.remoteBackup) {
      throw SyncFailure(
        'A pending operation ID was reused for different content.',
        path: operation.path,
      );
    }
  }

  void markSide(String id, {required bool local}) {
    final column = local ? 'local_done' : 'remote_done';
    _db.execute(
      'UPDATE pending_operations SET $column=1 WHERE operation_id=? AND complete=0',
      <Object?>[id],
    );
  }

  void markNeedsRescan(String id) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final rows = _db.select(
        'SELECT local_done,remote_done,complete FROM pending_operations WHERE operation_id=?',
        <Object?>[id],
      );
      if (rows.isEmpty ||
          (rows.single['local_done'] as int) != 0 ||
          (rows.single['remote_done'] as int) != 0 ||
          (rows.single['complete'] as int) != 0) {
        throw const SyncFailure(
          'A conditional WebDAV change was rejected after the operation had already changed a side; recovery was kept.',
          statusCode: 412,
        );
      }
      _db.execute(
        'UPDATE pending_operations SET needs_rescan=1 WHERE operation_id=?',
        <Object?>[id],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void finishRescan(String id) {
    _db.execute(
      'DELETE FROM pending_operations WHERE operation_id=? AND needs_rescan=1 AND local_done=0 AND remote_done=0 AND complete=0',
      <Object?>[id],
    );
  }

  void finishPath(String id, BaselineEntry? entry) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final rows = _db.select(
        'SELECT local_done,remote_done FROM pending_operations WHERE operation_id=?',
        <Object?>[id],
      );
      if (rows.isEmpty ||
          (rows.single['local_done'] as int) != 1 ||
          (rows.single['remote_done'] as int) != 1) {
        throw const SyncFailure(
          'A path cannot be confirmed until both sides are verified.',
        );
      }
      if (entry == null) {
        _db.execute(
          'DELETE FROM baseline WHERE relative_path=(SELECT relative_path FROM pending_operations WHERE operation_id=?)',
          <Object?>[id],
        );
      } else {
        _db.execute(
          '''INSERT INTO baseline(relative_path,sha256,local_modified_ms,remote_etag,remote_size)
          VALUES(?,?,?,?,?) ON CONFLICT(relative_path) DO UPDATE SET
          sha256=excluded.sha256,local_modified_ms=excluded.local_modified_ms,
          remote_etag=excluded.remote_etag,remote_size=excluded.remote_size''',
          <Object?>[
            entry.path.value,
            entry.sha256,
            entry.localModifiedMs,
            entry.remoteEtag,
            entry.remoteSize,
          ],
        );
      }
      _db.execute(
        'UPDATE pending_operations SET complete=1 WHERE operation_id=?',
        <Object?>[id],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void saveUnchangedBaseline(BaselineEntry entry) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        '''INSERT INTO baseline(relative_path,sha256,local_modified_ms,remote_etag,remote_size)
      VALUES(?,?,?,?,?) ON CONFLICT(relative_path) DO UPDATE SET
      sha256=excluded.sha256,local_modified_ms=excluded.local_modified_ms,
      remote_etag=excluded.remote_etag,remote_size=excluded.remote_size''',
        <Object?>[
          entry.path.value,
          entry.sha256,
          entry.localModifiedMs,
          entry.remoteEtag,
          entry.remoteSize,
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void deleteUnchangedBaseline(SyncPath path) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('DELETE FROM baseline WHERE relative_path=?', <Object?>[
        path.value,
      ]);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void finishCleanup(String id) {
    _db.execute(
      'DELETE FROM pending_operations WHERE operation_id=? AND complete=1',
      <Object?>[id],
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

typedef _CheckpointRow = ({
  String sha256,
  int size,
  int modifiedMs,
  String? etag,
});

final class _SqliteScanCheckpoint implements ScanCheckpoint {
  _SqliteScanCheckpoint(this._store, {required bool reuse})
    : _local = reuse ? _load(_store, 'local') : const {},
      _remote = reuse ? _load(_store, 'remote') : const {};

  final SqliteStateStore _store;
  final Map<String, _CheckpointRow> _local;
  final Map<String, _CheckpointRow> _remote;

  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');

  static Map<String, _CheckpointRow> _load(
    SqliteStateStore store,
    String side,
  ) {
    return <String, _CheckpointRow>{
      for (final row in store._db.select(
        'SELECT relative_path,sha256,size,modified_ms,etag FROM scan_checkpoint WHERE side=?',
        <Object?>[side],
      ))
        row['relative_path'] as String: (
          sha256: row['sha256'] as String,
          size: row['size'] as int,
          modifiedMs: row['modified_ms'] as int,
          etag: row['etag'] as String?,
        ),
    };
  }

  @override
  String? localHash(
    SyncPath path, {
    required int size,
    required int modifiedMs,
  }) {
    // Without a real modification time, size alone cannot identify content.
    if (size < 0 || modifiedMs <= 0) return null;
    final row = _local[path.value];
    if (row == null || row.size != size || row.modifiedMs != modifiedMs) {
      return null;
    }
    return _sha256.hasMatch(row.sha256) ? row.sha256 : null;
  }

  @override
  ({String sha256, int size})? remoteFile(
    SyncPath path, {
    required String etag,
    int? size,
  }) {
    final row = _remote[path.value];
    if (row == null || row.etag == null || row.etag != etag) return null;
    if (size != null && row.size != size) return null;
    if (!_sha256.hasMatch(row.sha256) || row.size < 0) return null;
    return (sha256: row.sha256, size: row.size);
  }

  @override
  void recordLocal(
    SyncPath path, {
    required String sha256,
    required int size,
    required int modifiedMs,
  }) {
    if (size < 0 || modifiedMs <= 0) return;
    _write('local', path, sha256, size, modifiedMs, null);
  }

  @override
  void recordRemote(
    SyncPath path, {
    required String sha256,
    required int size,
    required String etag,
  }) {
    _write('remote', path, sha256, size, 0, etag);
  }

  void _write(
    String side,
    SyncPath path,
    String sha256,
    int size,
    int modifiedMs,
    String? etag,
  ) {
    if (!_sha256.hasMatch(sha256)) return;
    _store._db.execute(
      '''INSERT INTO scan_checkpoint(side,relative_path,sha256,size,modified_ms,etag)
      VALUES(?,?,?,?,?,?) ON CONFLICT(side,relative_path) DO UPDATE SET
      sha256=excluded.sha256,size=excluded.size,
      modified_ms=excluded.modified_ms,etag=excluded.etag''',
      <Object?>[side, path.value, sha256, size, modifiedMs, etag],
    );
  }
}
