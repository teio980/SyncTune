import 'package:crypto/crypto.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import '../infrastructure/platform/broker_local_object_store.dart';

/// The broker scanner contract used by the sync composition root.
///
/// A UI music list may omit identity and hashes for responsiveness. A sync
/// snapshot cannot: the planner needs a stable identity and a complete hash
/// before it can create a baseline or a destructive operation.
abstract interface class BrokerLocalScanPort {
  Future<Map<Object?, Object?>> scan(
    BrokerRoot root, {
    CancellationToken token = const NeverCancelled(),
  });
}

/// Private catalog boundary used when native scan records do not yet carry a
/// stable document identity. The database implementation stores only this
/// opaque identity and a relative path scoped by root generation.
abstract interface class LocalCatalogStore {
  Future<String> ensureEntryId(SyncRoot root, SyncPath path);
}

/// Optional durable catalog extension used when a broker scan or remote
/// download supplies a stable identity and the local catalog must remember it
/// across a rename or a tombstone.
abstract interface class CatalogEntryStore extends LocalCatalogStore {
  Future<void> rememberEntry(SyncRoot root, SyncEntry entry);
  Future<SyncEntry?> loadCatalogEntry(SyncRoot root, SyncPath path);
  Future<List<SyncEntry>> loadCatalogEntries(SyncRoot root);
  Future<FavoriteStamp?> loadFavorite(String entryId);
  Future<void> saveCatalogFavorite(
    String entryId,
    SyncPath path,
    FavoriteStamp stamp,
  );
}

/// Optional clock boundary for adapters that persist remote favorite stamps.
/// Implementations advance the local Lamport clock before a later local write
/// allocates its stamp.
abstract interface class RemoteFavoriteLamportStore {
  Future<int> observeRemoteLamport(int remoteLamport);
}

/// Converts a broker-owned scan into the core's immutable local snapshot.
///
/// The Dart side never receives an absolute path. The active root is pinned for
/// the whole scan and checked again after the native call returns, so a root
/// switch cannot publish records from the previous authorization.
final class BrokerLocalSnapshotProvider implements LocalSnapshotProvider {
  BrokerLocalSnapshotProvider({
    required this.scanner,
    required this.root,
    required this.deviceId,
    this.catalog,
    this.objects,
    DateTime Function()? nowUtc,
  }) : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc()) {
    if (deviceId.trim().isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId');
    }
  }

  final BrokerLocalScanPort scanner;
  final BrokerRootPort root;
  final String deviceId;
  final LocalCatalogStore? catalog;
  final LocalObjectStore? objects;
  final DateTime Function() _nowUtc;

  @override
  Future<SyncSnapshot> capture(
    SyncRoot syncRoot, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final pinned = root.current;
    if (pinned == null || pinned.generation != syncRoot.generation) {
      throw const NeedsRescan('authorized root is unavailable or stale');
    }
    final response = await scanner.scan(pinned, token: token);
    token.throwIfCancelled();
    _ensurePinned(pinned, syncRoot);

    if (response['status'] != 'ok') {
      throw NeedsRescan(
        response['error']?.toString() ?? 'local broker scan failed',
      );
    }
    final returnedGeneration = response['generation']?.toString() ?? '';
    if (returnedGeneration != syncRoot.generation) {
      throw const NeedsRescan('local scan returned a stale generation');
    }
    final rawItems = response['items'];
    if (rawItems is! List) {
      throw const NeedsRescan('local broker scan did not return an item list');
    }
    final complete = response['complete'];
    if (complete is! bool) {
      throw const NeedsRescan('local broker scan omitted completeness');
    }

    final entries = <SyncEntry>[];
    for (final raw in rawItems) {
      token.throwIfCancelled();
      if (raw is! Map) {
        throw const NeedsRescan('local broker scan returned a malformed item');
      }
      entries.add(
        await _entry(
          Map<Object?, Object?>.from(raw),
          syncRoot: syncRoot,
          pinned: pinned,
          token: token,
        ),
      );
    }
    _ensurePinned(pinned, syncRoot);
    final catalogStore = catalog;
    if (catalogStore is CatalogEntryStore) {
      final stored = await catalogStore.loadCatalogEntries(syncRoot);
      final seen = entries.map((entry) => entry.path).toSet();
      for (final item in stored) {
        // A complete broker scan is authoritative for live files. Durable
        // tombstones are the exception: retaining them prevents a deleted
        // entry from being resurrected when the native scan omits it.
        if (item.isDeleted && !seen.contains(item.path)) {
          entries.add(item);
        }
      }
      _ensurePinned(pinned, syncRoot);
    }
    return SyncSnapshot(
      deviceId: deviceId,
      capturedAtUtc: _nowUtc().toUtc(),
      entries: entries,
      completeness: complete
          ? ScanCompleteness.complete
          : ScanCompleteness.partial,
      generation: syncRoot.generation,
    );
  }

  Future<SyncEntry> _entry(
    Map<Object?, Object?> raw, {
    required SyncRoot syncRoot,
    required BrokerRoot pinned,
    required CancellationToken token,
  }) async {
    final pathText = _requiredString(raw, 'relativePath');
    final path = SyncPath.parse(pathText);
    final catalogStore = catalog;
    SyncEntry? catalogEntry;
    if (catalogStore is CatalogEntryStore) {
      catalogEntry = await catalogStore.loadCatalogEntry(syncRoot, path);
      token.throwIfCancelled();
      _ensurePinned(pinned, syncRoot);
    }
    final id =
        _optionalString(raw, 'id') ??
        (catalogStore == null
            ? (throw const NeedsRescan(
                'local broker item has no stable identity',
              ))
            : await catalogStore.ensureEntryId(syncRoot, path));
    _ensurePinned(pinned, syncRoot);
    token.throwIfCancelled();
    final size = _requiredInt(raw, 'size');
    if (size < 0) throw const NeedsRescan('local broker item has invalid size');
    final rawHash = _optionalString(raw, 'sha256')?.toLowerCase();
    final sha256 = rawHash ?? await _hashFile(path, size, token);
    token.throwIfCancelled();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const NeedsRescan('local broker item has no complete SHA-256');
    }
    final modifiedAt = _modifiedAt(raw);
    var favorite = _favorite(raw, fallback: catalogEntry?.favorite);
    if (catalogEntry != null && catalogEntry.id == id) {
      favorite = favorite.merge(catalogEntry.favorite);
    }
    var entry = SyncEntry.file(
      id: id,
      path: path,
      size: size,
      modifiedAtUtc: modifiedAt,
      sha256: sha256,
      revision: _optionalInt(raw, 'revision') ?? 0,
      favorite: favorite,
    );
    if (catalogStore is CatalogEntryStore) {
      final storedFavorite = await catalogStore.loadFavorite(entry.id);
      token.throwIfCancelled();
      _ensurePinned(pinned, syncRoot);
      final mergedFavorite = storedFavorite == null
          ? entry.favorite
          : entry.favorite.merge(storedFavorite);
      if (storedFavorite == null || mergedFavorite != storedFavorite) {
        final lamportStore = catalogStore is RemoteFavoriteLamportStore
            ? catalogStore as RemoteFavoriteLamportStore
            : null;
        if (lamportStore != null &&
            (storedFavorite == null ||
                mergedFavorite.lamport > storedFavorite.lamport) &&
            mergedFavorite.lamport > 0) {
          await lamportStore.observeRemoteLamport(mergedFavorite.lamport);
          token.throwIfCancelled();
          _ensurePinned(pinned, syncRoot);
        }
        if (_shouldPersistFavorite(mergedFavorite)) {
          await catalogStore.saveCatalogFavorite(
            entry.id,
            path,
            mergedFavorite,
          );
          token.throwIfCancelled();
          _ensurePinned(pinned, syncRoot);
        }
      }
      entry = entry.copyWith(favorite: mergedFavorite);
      await catalogStore.rememberEntry(syncRoot, entry);
      token.throwIfCancelled();
      _ensurePinned(pinned, syncRoot);
    }
    return entry;
  }

  bool _shouldPersistFavorite(FavoriteStamp stamp) =>
      stamp.value || stamp.lamport > 0 || stamp.deviceId.isNotEmpty;

  FavoriteStamp _favorite(
    Map<Object?, Object?> raw, {
    FavoriteStamp? fallback,
  }) {
    if (!raw.containsKey('favorite') &&
        !raw.containsKey('favoriteLamport') &&
        !raw.containsKey('favoriteDeviceId') &&
        fallback != null) {
      return fallback;
    }
    final value = raw['favorite'];
    if (value != null && value is! bool) {
      throw const NeedsRescan('local broker favorite value is malformed');
    }
    final favoriteValue = value as bool?;
    final lamport = _optionalInt(raw, 'favoriteLamport') ?? 0;
    if (lamport < 0) {
      throw const NeedsRescan('local broker favorite clock is invalid');
    }
    final rawDevice = raw['favoriteDeviceId'];
    if (rawDevice != null && rawDevice is! String) {
      throw const NeedsRescan('local broker favorite device is malformed');
    }
    return FavoriteStamp(
      value: favoriteValue ?? false,
      lamport: lamport,
      deviceId: (rawDevice as String?) ?? deviceId,
    );
  }

  Future<String> _hashFile(
    SyncPath path,
    int expectedLength,
    CancellationToken token,
  ) async {
    final store = objects;
    if (store == null) {
      throw const NeedsRescan(
        'local broker item has no hash and no object reader is configured',
      );
    }
    final digestSink = _DigestSink();
    final input = sha256.startChunkedConversion(digestSink);
    var length = 0;
    final bytes = await store.read(path, token: token);
    await for (final chunk in bytes) {
      token.throwIfCancelled();
      input.add(chunk);
      length += chunk.length;
    }
    input.close();
    if (length != expectedLength) {
      throw NeedsRescan('broker size changed while hashing ${path.value}');
    }
    return digestSink.value.toString();
  }

  void _ensurePinned(BrokerRoot pinned, SyncRoot syncRoot) {
    final current = root.current;
    if (current?.token != pinned.token ||
        current?.generation != pinned.generation ||
        pinned.generation != syncRoot.generation) {
      throw const NeedsRescan('authorized root changed during local scan');
    }
  }

  String _requiredString(Map<Object?, Object?> raw, String name) {
    final value = raw[name];
    if (value is String && value.isNotEmpty) return value;
    throw NeedsRescan('local broker item omitted $name');
  }

  String? _optionalString(Map<Object?, Object?> raw, String name) {
    final value = raw[name];
    if (value == null) return null;
    if (value is String && value.isNotEmpty) return value;
    throw NeedsRescan('local broker item has invalid $name');
  }

  DateTime _modifiedAt(Map<Object?, Object?> raw) {
    final value = raw['modifiedAtUtc'];
    if (value == null) return _nowUtc().toUtc();
    if (value is! String) {
      throw const NeedsRescan(
        'local broker item has an invalid modification timestamp',
      );
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw const NeedsRescan(
        'local broker item has an invalid modification timestamp',
      );
    }
    return parsed.toUtc();
  }

  int _requiredInt(Map<Object?, Object?> raw, String name) {
    final value = raw[name];
    if (value is int) return value;
    if (value is num && value == value.toInt()) return value.toInt();
    throw NeedsRescan('local broker item omitted $name');
  }

  int? _optionalInt(Map<Object?, Object?> raw, String name) {
    final value = raw[name];
    if (value == null) return null;
    if (value is int) return value;
    if (value is num && value == value.toInt()) return value.toInt();
    throw NeedsRescan('local broker item has invalid $name');
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get value => _digest ?? (throw StateError('digest was not closed'));

  @override
  void add(Digest value) {
    if (_digest != null) throw StateError('digest was already provided');
    _digest = value;
  }

  @override
  void close() {
    if (_digest == null) throw StateError('digest was not provided');
  }
}
