import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import 'broker_local_snapshot_provider.dart';

/// Drift-backed metadata store. The executor is injected so platform code can
/// resolve its broker-authorized private path without exposing it to features.
final class SyncTuneDatabase extends GeneratedDatabase
    implements
        BaselineStore,
        JournalStore,
        CatalogEntryStore,
        RemoteFavoriteLamportStore,
        PlanStore {
  SyncTuneDatabase(super.executor);

  final StreamController<void> _favoriteChanges =
      StreamController<void>.broadcast();

  @override
  int get schemaVersion => 7;

  // The SQL schema is intentionally kept in one migration until drift_dev is
  // introduced. Queries still go through Drift's opened executor and bindings.
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const <TableInfo>[];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      // ignore: deprecated_member_use
      await m.issueCustomQuery('''
        CREATE TABLE favorites (
          entry_id TEXT PRIMARY KEY NOT NULL,
          relative_path TEXT NOT NULL,
          value INTEGER NOT NULL,
          lamport INTEGER NOT NULL,
          device_id TEXT NOT NULL
        )
      ''');
      // ignore: deprecated_member_use
      await m.issueCustomQuery('''
        CREATE TABLE baseline_state (
          root_id TEXT NOT NULL,
          generation TEXT NOT NULL,
          device_id TEXT NOT NULL,
          captured_at INTEGER NOT NULL,
          completeness TEXT NOT NULL,
          plan_id TEXT NOT NULL,
          PRIMARY KEY(root_id, generation)
        )
      ''');
      // ignore: deprecated_member_use
      await m.issueCustomQuery('''
        CREATE TABLE baseline_entries (
          root_id TEXT NOT NULL,
          generation TEXT NOT NULL,
          entry_id TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          kind TEXT NOT NULL,
          size INTEGER NOT NULL,
          modified_at INTEGER NOT NULL,
          sha256 TEXT,
          etag TEXT,
          revision INTEGER NOT NULL,
          favorite_value INTEGER NOT NULL,
          favorite_lamport INTEGER NOT NULL,
          favorite_device_id TEXT NOT NULL,
          PRIMARY KEY(root_id, generation, relative_path)
        )
      ''');
      // ignore: deprecated_member_use
      await m.issueCustomQuery('''
        CREATE TABLE sync_journal (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          plan_id TEXT NOT NULL,
          generation TEXT NOT NULL,
          operation_id TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          state TEXT NOT NULL,
          at_utc INTEGER NOT NULL,
          staging_key TEXT,
          sha256 TEXT,
          length INTEGER,
          condition TEXT,
          metadata_condition TEXT,
          error TEXT
        )
      ''');
      // The private catalog is intentionally separate from the confirmed
      // baseline. It survives ordinary rescans and gives a broker scan a
      // stable identity without exposing a path outside the granted root.
      // ignore: deprecated_member_use
      await m.issueCustomQuery('''
        CREATE TABLE local_catalog (
          root_id TEXT NOT NULL,
          generation TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          entry_id TEXT NOT NULL,
          PRIMARY KEY(root_id, generation, relative_path),
          UNIQUE(root_id, generation, entry_id)
        )
      ''');
      // Full catalog records retain stable identity and tombstones even when
      // a broker scan only returns the currently visible files.
      // ignore: deprecated_member_use
      await m.issueCustomQuery('''
        CREATE TABLE catalog_entries (
          root_id TEXT NOT NULL,
          generation TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          entry_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          size INTEGER NOT NULL,
          modified_at INTEGER NOT NULL,
          sha256 TEXT,
          etag TEXT,
          revision INTEGER NOT NULL,
          favorite_value INTEGER NOT NULL,
          favorite_lamport INTEGER NOT NULL,
          favorite_device_id TEXT NOT NULL,
          PRIMARY KEY(root_id, generation, relative_path)
        )
      ''');
      // Device identity and Lamport state stay in the broker-authorized
      // private database. Credentials never enter this table.
      // ignore: deprecated_member_use
      await m.issueCustomQuery('''
        CREATE TABLE device_state (
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
          device_id TEXT NOT NULL,
          lamport INTEGER NOT NULL
        )
      ''');
      // Endpoint, remote namespace and theme are non-secret preferences.
      // Passwords are provided by the platform secure-credential port.
      // ignore: deprecated_member_use
      await m.issueCustomQuery('''
        CREATE TABLE app_settings (
          setting_key TEXT PRIMARY KEY NOT NULL,
          setting_value TEXT NOT NULL
        )
      ''');
      // A pending plan is written before the first stage/mutation. The
      // payload is versioned by SyncPlanCodec and the unique key prevents a
      // retry from creating a second active copy of the same plan.
      // ignore: deprecated_member_use
      await m.issueCustomQuery('''
        CREATE TABLE sync_plans (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          root_id TEXT NOT NULL,
          generation TEXT NOT NULL,
          remote_namespace TEXT NOT NULL,
          plan_id TEXT NOT NULL,
          state TEXT NOT NULL,
          payload TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          UNIQUE(root_id, generation, remote_namespace, plan_id)
        )
      ''');
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // ignore: deprecated_member_use
        await m.issueCustomQuery(
          'ALTER TABLE sync_journal ADD COLUMN metadata_condition TEXT',
        );
      }
      if (from < 3) {
        // ignore: deprecated_member_use
        await m.issueCustomQuery('''
          CREATE TABLE local_catalog (
            root_id TEXT NOT NULL,
            generation TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            PRIMARY KEY(root_id, generation, relative_path),
            UNIQUE(root_id, generation, entry_id)
          )
        ''');
        // ignore: deprecated_member_use
        await m.issueCustomQuery('''
          CREATE TABLE device_state (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            device_id TEXT NOT NULL,
            lamport INTEGER NOT NULL
          )
        ''');
        // ignore: deprecated_member_use
        await m.issueCustomQuery('''
          CREATE TABLE app_settings (
            setting_key TEXT PRIMARY KEY NOT NULL,
            setting_value TEXT NOT NULL
          )
        ''');
      }
      if (from < 4) {
        // ignore: deprecated_member_use
        await m.issueCustomQuery('''
          CREATE TABLE sync_plans (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            root_id TEXT NOT NULL,
            generation TEXT NOT NULL,
            remote_namespace TEXT NOT NULL,
            plan_id TEXT NOT NULL,
            state TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(root_id, generation, remote_namespace, plan_id)
          )
        ''');
      }
      if (from < 5) {
        // ignore: deprecated_member_use
        await m.issueCustomQuery('''
          CREATE TABLE catalog_entries (
            root_id TEXT NOT NULL,
            generation TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
            sha256 TEXT,
            etag TEXT,
            revision INTEGER NOT NULL,
            favorite_value INTEGER NOT NULL,
            favorite_lamport INTEGER NOT NULL,
            favorite_device_id TEXT NOT NULL,
            PRIMARY KEY(root_id, generation, relative_path)
          )
        ''');
      }
      if (from < 6) {
        // Earlier schema versions accidentally made entry_id unique within a
        // generation, which prevented retaining a tombstone at the old path
        // when the same stable identity was observed at a renamed path.
        // Rebuild only this private metadata table; user files are untouched.
        // ignore: deprecated_member_use
        await m.issueCustomQuery('''
          CREATE TABLE catalog_entries_new (
            root_id TEXT NOT NULL,
            generation TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
            sha256 TEXT,
            etag TEXT,
            revision INTEGER NOT NULL,
            favorite_value INTEGER NOT NULL,
            favorite_lamport INTEGER NOT NULL,
            favorite_device_id TEXT NOT NULL,
            PRIMARY KEY(root_id, generation, relative_path)
          )
        ''');
        // ignore: deprecated_member_use
        await m.issueCustomQuery('''
          INSERT INTO catalog_entries_new
          SELECT root_id, generation, relative_path, entry_id, kind, size,
                 modified_at, sha256, etag, revision, favorite_value,
                 favorite_lamport, favorite_device_id
          FROM catalog_entries
        ''');
        // ignore: deprecated_member_use
        await m.issueCustomQuery('DROP TABLE catalog_entries');
        // ignore: deprecated_member_use
        await m.issueCustomQuery(
          'ALTER TABLE catalog_entries_new RENAME TO catalog_entries',
        );
      }
      if (from < 7) {
        // A stable identity may legitimately occur at both a renamed live
        // path and its durable tombstone path. Baselines are indexed by path,
        // just like snapshots, so retaining both must not hit an entry_id
        // uniqueness constraint.
        // ignore: deprecated_member_use
        await m.issueCustomQuery('''
          CREATE TABLE baseline_entries_new (
            root_id TEXT NOT NULL,
            generation TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
            sha256 TEXT,
            etag TEXT,
            revision INTEGER NOT NULL,
            favorite_value INTEGER NOT NULL,
            favorite_lamport INTEGER NOT NULL,
            favorite_device_id TEXT NOT NULL,
            PRIMARY KEY(root_id, generation, relative_path)
          )
        ''');
        // ignore: deprecated_member_use
        await m.issueCustomQuery('''
          INSERT INTO baseline_entries_new
          SELECT root_id, generation, entry_id, relative_path, kind, size,
                 modified_at, sha256, etag, revision, favorite_value,
                 favorite_lamport, favorite_device_id
          FROM baseline_entries
        ''');
        // ignore: deprecated_member_use
        await m.issueCustomQuery('DROP TABLE baseline_entries');
        // ignore: deprecated_member_use
        await m.issueCustomQuery(
          'ALTER TABLE baseline_entries_new RENAME TO baseline_entries',
        );
      }
    },
  );

  Future<void> saveFavorite({
    required String entryId,
    required String relativePath,
    required bool value,
    required int lamport,
    required String deviceId,
  }) async {
    await customInsert(
      '''
      INSERT INTO favorites(entry_id, relative_path, value, lamport, device_id)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(entry_id) DO UPDATE SET
        relative_path = excluded.relative_path,
        value = excluded.value,
        lamport = excluded.lamport,
        device_id = excluded.device_id
      WHERE excluded.lamport > favorites.lamport
         OR (excluded.lamport = favorites.lamport AND excluded.device_id >= favorites.device_id)
      ''',
      variables: [
        Variable.withString(entryId),
        Variable.withString(relativePath),
        Variable.withBool(value),
        Variable.withInt(lamport),
        Variable.withString(deviceId),
      ],
    );
    _favoriteChanges.add(null);
  }

  Stream<List<FavoriteRow>> watchFavorites() {
    late StreamController<List<FavoriteRow>> controller;
    StreamSubscription<void>? changes;
    controller = StreamController<List<FavoriteRow>>(
      onListen: () {
        changes = _favoriteChanges.stream.listen((_) async {
          try {
            if (!controller.isClosed) {
              controller.add(await _loadFavorites());
            }
          } catch (error, stackTrace) {
            if (!controller.isClosed) controller.addError(error, stackTrace);
          }
        });
        () async {
          try {
            if (!controller.isClosed) {
              controller.add(await _loadFavorites());
            }
          } catch (error, stackTrace) {
            if (!controller.isClosed) controller.addError(error, stackTrace);
          }
        }();
      },
      onCancel: () => changes?.cancel(),
    );
    return controller.stream;
  }

  Future<List<FavoriteRow>> _loadFavorites() async {
    final rows = await customSelect(
      'SELECT entry_id, relative_path, value, lamport, device_id '
      'FROM favorites ORDER BY relative_path',
    ).get();
    return rows
        .map(
          (row) => FavoriteRow(
            entryId: row.read<String>('entry_id'),
            relativePath: row.read<String>('relative_path'),
            value: row.read<int>('value') != 0,
            lamport: row.read<int>('lamport'),
            deviceId: row.read<String>('device_id'),
          ),
        )
        .toList(growable: false);
  }

  /// Returns the stable per-install device identity, creating it only inside
  /// the private database. The identifier is opaque and never derived from a
  /// user path, endpoint, or credential.
  Future<String> loadOrCreateDeviceId() async {
    final existing = await customSelect(
      'SELECT device_id FROM device_state WHERE singleton = 1',
    ).get();
    if (existing.isNotEmpty) return existing.single.read<String>('device_id');
    final generated = _newDeviceId();
    await customInsert(
      'INSERT OR IGNORE INTO device_state(singleton, device_id, lamport) '
      'VALUES (1, ?, 0)',
      variables: [Variable.withString(generated)],
    );
    final persisted = await customSelect(
      'SELECT device_id FROM device_state WHERE singleton = 1',
    ).get();
    if (persisted.isEmpty) {
      throw StateError('Device identity was not persisted');
    }
    return persisted.single.read<String>('device_id');
  }

  Future<int> nextLamport() async {
    await loadOrCreateDeviceId();
    return transaction(() async {
      final rows = await customSelect(
        'SELECT lamport FROM device_state WHERE singleton = 1',
      ).get();
      if (rows.isEmpty) throw StateError('Device identity is unavailable');
      // Remote favorite stamps are observed before allocating a local stamp.
      // The durable favorite table is the merge boundary, so this also covers
      // a remote snapshot that was persisted before the UI asked for a new
      // local favorite value.
      final remoteRows = await customSelect(
        'SELECT COALESCE(MAX(lamport), 0) AS max_lamport FROM favorites',
      ).get();
      final observed = remoteRows.single.read<int>('max_lamport');
      final next =
          (rows.single.read<int>('lamport') > observed
              ? rows.single.read<int>('lamport')
              : observed) +
          1;
      await customUpdate(
        'UPDATE device_state SET lamport = ? WHERE singleton = 1',
        variables: [Variable.withInt(next)],
      );
      return next;
    });
  }

  /// Observes a remote Lamport value and allocates the next local value in a
  /// single transaction. This is intentionally separate from [saveFavorite]
  /// so adapters can advance the clock even when a remote favorite loses the
  /// value merge and is not written locally.
  Future<int> observeLamport(int remoteLamport) async {
    if (remoteLamport < 0) {
      throw ArgumentError.value(remoteLamport, 'remoteLamport');
    }
    await loadOrCreateDeviceId();
    return transaction(() async {
      final rows = await customSelect(
        'SELECT lamport FROM device_state WHERE singleton = 1',
      ).get();
      if (rows.isEmpty) throw StateError('Device identity is unavailable');
      final current = rows.single.read<int>('lamport');
      final next = (current > remoteLamport ? current : remoteLamport) + 1;
      await customUpdate(
        'UPDATE device_state SET lamport = ? WHERE singleton = 1',
        variables: [Variable.withInt(next)],
      );
      return next;
    });
  }

  @override
  Future<int> observeRemoteLamport(int remoteLamport) =>
      observeLamport(remoteLamport);

  Future<String?> loadSetting(String key) async {
    if (key.isEmpty) throw ArgumentError.value(key, 'key');
    final rows = await customSelect(
      'SELECT setting_value FROM app_settings WHERE setting_key = ?',
      variables: [Variable.withString(key)],
    ).get();
    return rows.isEmpty ? null : rows.single.read<String>('setting_value');
  }

  Future<void> saveSetting(String key, String value) async {
    if (key.isEmpty) throw ArgumentError.value(key, 'key');
    await customInsert(
      'INSERT INTO app_settings(setting_key, setting_value) VALUES (?, ?) '
      'ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value',
      variables: [Variable.withString(key), Variable.withString(value)],
    );
  }

  Future<void> deleteSetting(String key) async {
    if (key.isEmpty) throw ArgumentError.value(key, 'key');
    await customUpdate(
      'DELETE FROM app_settings WHERE setting_key = ?',
      variables: [Variable.withString(key)],
    );
  }

  Future<String?> loadCatalogEntryId(SyncRoot root, SyncPath path) async {
    final rows = await customSelect(
      'SELECT entry_id FROM local_catalog '
      'WHERE root_id = ? AND generation = ? AND relative_path = ?',
      variables: [
        Variable.withString(root.storageKey),
        Variable.withString(root.generation),
        Variable.withString(path.value),
      ],
    ).get();
    return rows.isEmpty ? null : rows.single.read<String>('entry_id');
  }

  Future<String> ensureCatalogEntryId(SyncRoot root, SyncPath path) async {
    final existing = await loadCatalogEntryId(root, path);
    if (existing != null) return existing;
    // Identity is generated once and persisted in the private catalog. It is
    // deliberately independent of the path, grant token, endpoint and root
    // generation: a rename or a root rebind must carry the same identity
    // rather than encoding sensitive authorization material into an ID.
    final generated = _newEntryId();
    await customInsert(
      'INSERT OR IGNORE INTO local_catalog '
      '(root_id, generation, relative_path, entry_id) VALUES (?, ?, ?, ?)',
      variables: [
        Variable.withString(root.storageKey),
        Variable.withString(root.generation),
        Variable.withString(path.value),
        Variable.withString(generated),
      ],
    );
    return await loadCatalogEntryId(root, path) ?? generated;
  }

  @override
  Future<String> ensureEntryId(SyncRoot root, SyncPath path) =>
      ensureCatalogEntryId(root, path);

  @override
  Future<void> rememberEntry(SyncRoot root, SyncEntry entry) async {
    await transaction(() async {
      // A remote rename may present the same stable identity at a new path.
      // Remove only the stale catalog alias for this root generation; the
      // confirmed baseline remains untouched until the run succeeds.
      await customUpdate(
        '''DELETE FROM local_catalog
           WHERE root_id = ? AND generation = ? AND entry_id = ?
             AND relative_path <> ?''',
        variables: [
          Variable.withString(root.storageKey),
          Variable.withString(root.generation),
          Variable.withString(entry.id),
          Variable.withString(entry.path.value),
        ],
      );
      await customInsert(
        '''INSERT INTO local_catalog(root_id, generation, relative_path, entry_id)
           VALUES (?, ?, ?, ?)
           ON CONFLICT(root_id, generation, relative_path)
           DO UPDATE SET entry_id = excluded.entry_id''',
        variables: [
          Variable.withString(root.storageKey),
          Variable.withString(root.generation),
          Variable.withString(entry.path.value),
          Variable.withString(entry.id),
        ],
      );
      final previousRows = await customSelect(
        '''SELECT entry_id, relative_path, kind, size, modified_at, sha256,
                  etag, revision, favorite_value, favorite_lamport,
                  favorite_device_id
           FROM catalog_entries
           WHERE root_id = ? AND generation = ? AND entry_id = ?
             AND relative_path <> ?''',
        variables: [
          Variable.withString(root.storageKey),
          Variable.withString(root.generation),
          Variable.withString(entry.id),
          Variable.withString(entry.path.value),
        ],
      ).get();
      for (final row in previousRows) {
        final previous = _entryFromRow(row);
        if (!previous.isDeleted) {
          await _upsertCatalogEntry(
            root,
            SyncEntry.tombstone(
              id: previous.id,
              path: previous.path,
              modifiedAtUtc: entry.modifiedAtUtc,
              revision: previous.revision + 1,
              favorite: previous.favorite,
            ),
          );
        }
      }
      await _upsertCatalogEntry(root, entry);
    });
  }

  Future<void> _upsertCatalogEntry(SyncRoot root, SyncEntry entry) =>
      customInsert(
        '''INSERT INTO catalog_entries
           (root_id, generation, relative_path, entry_id, kind, size,
            modified_at, sha256, etag, revision, favorite_value,
            favorite_lamport, favorite_device_id)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(root_id, generation, relative_path)
           DO UPDATE SET entry_id = excluded.entry_id,
             kind = excluded.kind, size = excluded.size,
             modified_at = excluded.modified_at, sha256 = excluded.sha256,
             etag = excluded.etag, revision = excluded.revision,
             favorite_value = excluded.favorite_value,
             favorite_lamport = excluded.favorite_lamport,
             favorite_device_id = excluded.favorite_device_id''',
        variables: [
          Variable.withString(root.storageKey),
          Variable.withString(root.generation),
          Variable.withString(entry.path.value),
          Variable.withString(entry.id),
          Variable.withString(entry.kind.name),
          Variable.withInt(entry.size),
          Variable.withInt(entry.modifiedAtUtc.microsecondsSinceEpoch),
          if (entry.sha256 == null)
            Variable<Object>(null)
          else
            Variable.withString(entry.sha256!),
          if (entry.etag == null)
            Variable<Object>(null)
          else
            Variable.withString(entry.etag!),
          Variable.withInt(entry.revision),
          Variable.withBool(entry.favorite.value),
          Variable.withInt(entry.favorite.lamport),
          Variable.withString(entry.favorite.deviceId),
        ],
      );

  @override
  Future<SyncEntry?> loadCatalogEntry(SyncRoot root, SyncPath path) async {
    final rows = await customSelect(
      '''SELECT entry_id, relative_path, kind, size, modified_at, sha256,
                etag, revision, favorite_value, favorite_lamport,
                favorite_device_id
         FROM catalog_entries
         WHERE root_id = ? AND generation = ? AND relative_path = ?''',
      variables: [
        Variable.withString(root.storageKey),
        Variable.withString(root.generation),
        Variable.withString(path.value),
      ],
    ).get();
    return rows.isEmpty ? null : _entryFromRow(rows.single);
  }

  @override
  Future<List<SyncEntry>> loadCatalogEntries(SyncRoot root) async {
    final rows = await customSelect(
      '''SELECT entry_id, relative_path, kind, size, modified_at, sha256,
                etag, revision, favorite_value, favorite_lamport,
                favorite_device_id
         FROM catalog_entries
         WHERE root_id = ? AND generation = ?
         ORDER BY relative_path''',
      variables: [
        Variable.withString(root.storageKey),
        Variable.withString(root.generation),
      ],
    ).get();
    return rows.map(_entryFromRow).toList(growable: false);
  }

  @override
  Future<FavoriteStamp?> loadFavorite(String entryId) async {
    if (entryId.isEmpty) throw ArgumentError.value(entryId, 'entryId');
    final rows = await customSelect(
      'SELECT value, lamport, device_id FROM favorites WHERE entry_id = ?',
      variables: [Variable.withString(entryId)],
    ).get();
    if (rows.isEmpty) return null;
    final row = rows.single;
    return FavoriteStamp(
      value: row.read<int>('value') != 0,
      lamport: row.read<int>('lamport'),
      deviceId: row.read<String>('device_id'),
    );
  }

  @override
  Future<void> saveCatalogFavorite(
    String entryId,
    SyncPath path,
    FavoriteStamp stamp,
  ) => saveFavorite(
    entryId: entryId,
    relativePath: path.value,
    value: stamp.value,
    lamport: stamp.lamport,
    deviceId: stamp.deviceId,
  );

  String _newDeviceId() =>
      'device-${base64UrlEncode(List<int>.generate(16, (_) => Random.secure().nextInt(256))).replaceAll('=', '')}';

  String _newEntryId() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    // UUID v4 and RFC 4122 variant bits keep IDs recognizable while all
    // identity material remains random and opaque.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  @override
  Future<SyncSnapshot?> load(SyncRoot root) async {
    return transaction(() async {
      final stateRows = await customSelect(
        'SELECT device_id, captured_at, completeness FROM baseline_state '
        'WHERE root_id = ? AND generation = ?',
        variables: [
          Variable.withString(root.storageKey),
          Variable.withString(root.generation),
        ],
      ).get();
      if (stateRows.isEmpty) return null;
      final state = stateRows.single;
      final rows = await customSelect(
        'SELECT entry_id, relative_path, kind, size, modified_at, sha256, etag, '
        'revision, favorite_value, favorite_lamport, favorite_device_id '
        'FROM baseline_entries WHERE root_id = ? AND generation = ?',
        variables: [
          Variable.withString(root.storageKey),
          Variable.withString(root.generation),
        ],
      ).get();
      return SyncSnapshot(
        deviceId: state.read<String>('device_id'),
        capturedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          state.read<int>('captured_at'),
          isUtc: true,
        ),
        completeness: ScanCompleteness.values.byName(
          state.read<String>('completeness'),
        ),
        generation: root.generation,
        entries: rows.map(_entryFromRow),
      );
    });
  }

  SyncEntry _entryFromRow(QueryRow row) {
    final path = SyncPath.parse(row.read<String>('relative_path'));
    final favorite = FavoriteStamp(
      value: row.read<int>('favorite_value') != 0,
      lamport: row.read<int>('favorite_lamport'),
      deviceId: row.read<String>('favorite_device_id'),
    );
    final kind = row.read<String>('kind');
    final modifiedAt = DateTime.fromMicrosecondsSinceEpoch(
      row.read<int>('modified_at'),
      isUtc: true,
    );
    if (kind == SyncEntryKind.file.name) {
      return SyncEntry.file(
        id: row.read<String>('entry_id'),
        path: path,
        size: row.read<int>('size'),
        modifiedAtUtc: modifiedAt,
        sha256: row.read<String>('sha256'),
        etag: row.readNullable<String>('etag'),
        revision: row.read<int>('revision'),
        favorite: favorite,
      );
    }
    if (kind == SyncEntryKind.directory.name) {
      return SyncEntry.directory(
        id: row.read<String>('entry_id'),
        path: path,
        modifiedAtUtc: modifiedAt,
        etag: row.readNullable<String>('etag'),
        revision: row.read<int>('revision'),
        favorite: favorite,
      );
    }
    if (kind == SyncEntryKind.tombstone.name) {
      return SyncEntry.tombstone(
        id: row.read<String>('entry_id'),
        path: path,
        modifiedAtUtc: modifiedAt,
        revision: row.read<int>('revision'),
        favorite: favorite,
      );
    }
    throw StateError('Unknown baseline entry kind: $kind');
  }

  @override
  Future<void> saveConfirmed(
    SyncRoot root,
    SyncSnapshot snapshot, {
    required String planId,
  }) async {
    if (snapshot.generation != root.generation) {
      throw StateError('Baseline generation does not match the active root.');
    }
    if (!snapshot.complete) {
      throw NeedsRescan(
        'A partial or unauthorized scan cannot become baseline.',
      );
    }
    await transaction(() async {
      await customUpdate(
        'DELETE FROM baseline_entries WHERE root_id = ? AND generation = ?',
        variables: [
          Variable.withString(root.storageKey),
          Variable.withString(root.generation),
        ],
      );
      await customUpdate(
        'DELETE FROM baseline_state WHERE root_id = ? AND generation = ?',
        variables: [
          Variable.withString(root.storageKey),
          Variable.withString(root.generation),
        ],
      );
      await customInsert(
        'INSERT INTO baseline_state(root_id, generation, device_id, captured_at, completeness, plan_id) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString(root.storageKey),
          Variable.withString(root.generation),
          Variable.withString(snapshot.deviceId),
          Variable.withInt(snapshot.capturedAtUtc.microsecondsSinceEpoch),
          Variable.withString(snapshot.completeness.name),
          Variable.withString(planId),
        ],
      );
      for (final entry in snapshot.entries.values) {
        await customInsert(
          'INSERT INTO baseline_entries '
          '(root_id, generation, entry_id, relative_path, kind, size, modified_at, sha256, etag, revision, '
          'favorite_value, favorite_lamport, favorite_device_id) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable.withString(root.storageKey),
            Variable.withString(root.generation),
            Variable.withString(entry.id),
            Variable.withString(entry.path.value),
            Variable.withString(entry.kind.name),
            Variable.withInt(entry.size),
            Variable.withInt(entry.modifiedAtUtc.microsecondsSinceEpoch),
            if (entry.sha256 == null)
              Variable<Object>(null)
            else
              Variable.withString(entry.sha256!),
            if (entry.etag == null)
              Variable<Object>(null)
            else
              Variable.withString(entry.etag!),
            Variable.withInt(entry.revision),
            Variable.withBool(entry.favorite.value),
            Variable.withInt(entry.favorite.lamport),
            Variable.withString(entry.favorite.deviceId),
          ],
        );
      }
    });
  }

  @override
  Future<List<JournalRecord>> recordsFor(
    String planId,
    String generation,
  ) async {
    final rows = await customSelect(
      'SELECT operation_id, relative_path, state, at_utc, staging_key, sha256, '
      'length, condition, metadata_condition, error FROM sync_journal WHERE plan_id = ? AND generation = ? '
      'ORDER BY sequence',
      variables: [Variable.withString(planId), Variable.withString(generation)],
    ).get();
    return rows
        .map(
          (row) => JournalRecord(
            planId: planId,
            generation: generation,
            operationId: row.read<String>('operation_id'),
            path: SyncPath.parse(row.read<String>('relative_path')),
            state: JournalState.values.byName(row.read<String>('state')),
            atUtc: DateTime.fromMicrosecondsSinceEpoch(
              row.read<int>('at_utc'),
              isUtc: true,
            ),
            stagingKey: row.readNullable<String>('staging_key'),
            sha256: row.readNullable<String>('sha256'),
            length: row.readNullable<int>('length'),
            condition: row.readNullable<String>('condition'),
            metadataCondition: row.readNullable<String>('metadata_condition'),
            error: row.readNullable<String>('error'),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> append(JournalRecord record) async {
    await customInsert(
      'INSERT INTO sync_journal '
      '(plan_id, generation, operation_id, relative_path, state, at_utc, staging_key, sha256, length, condition, metadata_condition, error) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable.withString(record.planId),
        Variable.withString(record.generation),
        Variable.withString(record.operationId),
        Variable.withString(record.path.value),
        Variable.withString(record.state.name),
        Variable.withInt(record.atUtc.microsecondsSinceEpoch),
        if (record.stagingKey == null)
          Variable<Object>(null)
        else
          Variable.withString(record.stagingKey!),
        if (record.sha256 == null)
          Variable<Object>(null)
        else
          Variable.withString(record.sha256!),
        if (record.length == null)
          Variable<Object>(null)
        else
          Variable.withInt(record.length!),
        if (record.condition == null)
          Variable<Object>(null)
        else
          Variable.withString(record.condition!),
        if (record.metadataCondition == null)
          Variable<Object>(null)
        else
          Variable.withString(record.metadataCondition!),
        if (record.error == null)
          Variable<Object>(null)
        else
          Variable.withString(record.error!),
      ],
    );
  }

  @override
  Future<void> savePlan(SyncRoot root, SyncPlan plan) async {
    if (plan.generation != root.generation ||
        plan.remoteNamespace != root.remoteNamespace) {
      throw StateError('Plan scope does not match the active sync root.');
    }
    final payload = SyncPlanCodec.encode(plan);
    await customInsert(
      '''INSERT INTO sync_plans
        (root_id, generation, remote_namespace, plan_id, state, payload, updated_at)
        VALUES (?, ?, ?, ?, 'active', ?, ?)
        ON CONFLICT(root_id, generation, remote_namespace, plan_id)
        DO UPDATE SET state = 'active', payload = excluded.payload,
          updated_at = excluded.updated_at''',
      variables: [
        Variable.withString(root.storageKey),
        Variable.withString(root.generation),
        Variable.withString(root.remoteNamespace),
        Variable.withString(plan.planId),
        Variable.withString(payload),
        Variable.withInt(DateTime.now().toUtc().microsecondsSinceEpoch),
      ],
    );
  }

  @override
  Future<SyncPlan?> loadUnfinishedPlan(SyncRoot root) async {
    final rows = await customSelect(
      '''SELECT payload FROM sync_plans
         WHERE root_id = ? AND generation = ? AND remote_namespace = ?
           AND state = 'active'
         ORDER BY sequence DESC LIMIT 1''',
      variables: [
        Variable.withString(root.storageKey),
        Variable.withString(root.generation),
        Variable.withString(root.remoteNamespace),
      ],
    ).get();
    if (rows.isEmpty) return null;
    final plan = SyncPlanCodec.decode(rows.single.read<String>('payload'));
    if (plan.generation != root.generation ||
        plan.remoteNamespace != root.remoteNamespace) {
      throw NeedsRescan('Persisted plan scope does not match the active root.');
    }
    return plan;
  }

  @override
  Future<void> markPlanFinished(SyncRoot root, String planId) async {
    await customUpdate(
      '''UPDATE sync_plans SET state = 'finished', updated_at = ?
         WHERE root_id = ? AND generation = ? AND remote_namespace = ?
           AND plan_id = ?''',
      variables: [
        Variable.withInt(DateTime.now().toUtc().microsecondsSinceEpoch),
        Variable.withString(root.storageKey),
        Variable.withString(root.generation),
        Variable.withString(root.remoteNamespace),
        Variable.withString(planId),
      ],
    );
  }

  @override
  Future<void> markPlanSuperseded(SyncRoot root, String planId) async {
    await customUpdate(
      '''UPDATE sync_plans SET state = 'superseded', updated_at = ?
         WHERE root_id = ? AND generation = ? AND remote_namespace = ?
           AND plan_id = ?''',
      variables: [
        Variable.withInt(DateTime.now().toUtc().microsecondsSinceEpoch),
        Variable.withString(root.storageKey),
        Variable.withString(root.generation),
        Variable.withString(root.remoteNamespace),
        Variable.withString(planId),
      ],
    );
  }

  @override
  Future<void> close() async {
    await _favoriteChanges.close();
    await super.close();
  }

  Future<void> closeStore() => close();
}

final class FavoriteRow {
  const FavoriteRow({
    required this.entryId,
    required this.relativePath,
    required this.value,
    required this.lamport,
    required this.deviceId,
  });

  final String entryId;
  final String relativePath;
  final bool value;
  final int lamport;
  final String deviceId;
}

SyncTuneDatabase openSyncTuneDatabase(String privatePath) {
  if (privatePath.isEmpty) {
    throw ArgumentError.value(privatePath, 'privatePath');
  }
  return SyncTuneDatabase(NativeDatabase(File(privatePath)));
}
