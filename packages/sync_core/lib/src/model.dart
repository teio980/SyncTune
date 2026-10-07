import 'dart:collection';

final class SyncPath implements Comparable<SyncPath> {
  SyncPath._(this.value) : segments = UnmodifiableListView(value.split('/'));
  factory SyncPath.parse(String raw) {
    final normalized = raw.replaceAll('\\', '/');
    if (raw.isEmpty ||
        raw.contains('\u0000') ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw FormatException('Invalid absolute sync path.');
    }
    const reserved = <String>{
      'CON',
      'PRN',
      'AUX',
      'NUL',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9'
    };
    final parts = normalized.split('/');
    for (final part in parts) {
      final basename = part.split('.').first.toUpperCase();
      if (part.isEmpty ||
          part == '.' ||
          part == '..' ||
          part.contains(':') ||
          part.endsWith('.') ||
          part.endsWith(' ') ||
          RegExp(r'[\u0000-\u001F<>"|?*]').hasMatch(part) ||
          reserved.contains(basename)) {
        throw FormatException('Invalid sync path segment.');
      }
    }
    return SyncPath._(parts.join('/'));
  }
  final String value;
  final List<String> segments;
  @override
  int compareTo(SyncPath other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) => other is SyncPath && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

enum SyncEntryKind { file, directory, tombstone }

final class FavoriteStamp {
  const FavoriteStamp(
      {required this.value, required this.lamport, required this.deviceId});
  final bool value;
  final int lamport;
  final String deviceId;
  FavoriteStamp merge(FavoriteStamp other) {
    final clock = lamport.compareTo(other.lamport);
    if (clock != 0) return clock > 0 ? this : other;
    return deviceId.compareTo(other.deviceId) >= 0 ? this : other;
  }

  @override
  bool operator ==(Object other) =>
      other is FavoriteStamp &&
      other.value == value &&
      other.lamport == lamport &&
      other.deviceId == deviceId;
  @override
  int get hashCode => Object.hash(value, lamport, deviceId);
}

final class SyncEntry {
  SyncEntry._(
      {required this.id,
      required this.path,
      required this.kind,
      required this.size,
      required this.modifiedAtUtc,
      required this.sha256,
      required this.etag,
      required this.revision,
      required this.favorite});
  factory SyncEntry.file({
    required String id,
    required SyncPath path,
    required int size,
    required DateTime modifiedAtUtc,
    required String sha256,
    String? etag,
    int revision = 0,
    FavoriteStamp favorite =
        const FavoriteStamp(value: false, lamport: 0, deviceId: ''),
  }) {
    if (size < 0) {
      throw const FormatException('File size cannot be negative.');
    }
    if (revision < 0) {
      throw const FormatException('Revision cannot be negative.');
    }
    return SyncEntry._(
      id: id,
      path: path,
      kind: SyncEntryKind.file,
      size: size,
      modifiedAtUtc: modifiedAtUtc.toUtc(),
      sha256: _hash(sha256),
      etag: etag,
      revision: revision,
      favorite: favorite,
    );
  }
  factory SyncEntry.directory(
          {required String id,
          required SyncPath path,
          required DateTime modifiedAtUtc,
          String? etag,
          int revision = 0,
          FavoriteStamp favorite =
              const FavoriteStamp(value: false, lamport: 0, deviceId: '')}) =>
      SyncEntry._(
          id: id,
          path: path,
          kind: SyncEntryKind.directory,
          size: 0,
          modifiedAtUtc: modifiedAtUtc.toUtc(),
          sha256: null,
          etag: etag,
          revision: revision,
          favorite: favorite);
  factory SyncEntry.tombstone(
          {required String id,
          required SyncPath path,
          required DateTime modifiedAtUtc,
          int revision = 0,
          FavoriteStamp favorite =
              const FavoriteStamp(value: false, lamport: 0, deviceId: '')}) =>
      SyncEntry._(
          id: id,
          path: path,
          kind: SyncEntryKind.tombstone,
          size: 0,
          modifiedAtUtc: modifiedAtUtc.toUtc(),
          sha256: null,
          etag: null,
          revision: revision,
          favorite: favorite);
  static String _hash(String value) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value)) {
      throw FormatException('SHA-256 hex is required.');
    }
    return value.toLowerCase();
  }

  final String id;
  final SyncPath path;
  final SyncEntryKind kind;
  final int size;
  final DateTime modifiedAtUtc;
  final String? sha256;
  final String? etag;
  final int revision;
  final FavoriteStamp favorite;
  bool get isDeleted => kind == SyncEntryKind.tombstone;
  SyncEntry copyWith({
    String? id,
    SyncPath? path,
    FavoriteStamp? favorite,
    int? revision,
  }) =>
      SyncEntry._(
          id: id ?? this.id,
          path: path ?? this.path,
          kind: kind,
          size: size,
          modifiedAtUtc: modifiedAtUtc,
          sha256: sha256,
          etag: etag,
          revision: revision ?? this.revision,
          favorite: favorite ?? this.favorite);
  bool contentEquals(SyncEntry other) =>
      id == other.id &&
      path == other.path &&
      kind == other.kind &&
      size == other.size &&
      sha256 == other.sha256;
}

enum ScanCompleteness { complete, partial, unauthorized }

final class SyncSnapshot {
  SyncSnapshot(
      {required this.deviceId,
      required this.capturedAtUtc,
      required Iterable<SyncEntry> entries,
      this.completeness = ScanCompleteness.complete,
      required this.generation})
      : entries = UnmodifiableMapView(_index(entries));
  static Map<SyncPath, SyncEntry> _index(Iterable<SyncEntry> items) {
    final out = <SyncPath, SyncEntry>{};
    for (final item in items) {
      if (out.containsKey(item.path)) throw ArgumentError('Duplicate path');
      out[item.path] = item;
    }
    return out;
  }

  final String deviceId;
  final DateTime capturedAtUtc;
  final Map<SyncPath, SyncEntry> entries;
  final ScanCompleteness completeness;
  final String generation;
  bool get complete => completeness == ScanCompleteness.complete;
  SyncEntry? operator [](SyncPath path) => entries[path];
}

final class SyncRoot {
  const SyncRoot(
    this.id, {
    required this.generation,
    this.remoteNamespace = 'default',
  });
  final String id;
  final String generation;

  /// Stable identity of the configured remote namespace. Changing the
  /// endpoint or remote root changes this key and therefore cannot reuse a
  /// baseline captured against another server or collection.
  final String remoteNamespace;
  String get storageKey => '$id|$remoteNamespace';
}
