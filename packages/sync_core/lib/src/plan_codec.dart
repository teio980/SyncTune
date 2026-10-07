import 'dart:convert';

import 'model.dart';
import 'planner.dart';
import 'ports.dart';

/// Versioned, lossless JSON representation of a pending synchronization plan.
///
/// The codec deliberately stores both content and metadata conditions, both
/// sides of a conflict, and every source entry field. A plan is therefore
/// safe to persist before staging and can be inspected after a process restart
/// without reconstructing identity from a path.
final class SyncPlanCodec {
  const SyncPlanCodec._();

  static String encode(SyncPlan plan) => jsonEncode(toJson(plan));

  static Map<String, Object?> toJson(SyncPlan plan) => <String, Object?>{
        'schema': 1,
        'planId': plan.planId,
        'generation': plan.generation,
        'remoteNamespace': plan.remoteNamespace,
        'deletionsSuppressed': plan.deletionsSuppressed,
        'operations': plan.operations.map(_operationToJson).toList(),
      };

  static SyncPlan decode(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map) {
      throw const FormatException('Plan JSON must be an object.');
    }
    return fromJson(Map<String, Object?>.from(value));
  }

  static SyncPlan fromJson(Map<String, Object?> json) {
    if (_int(json, 'schema') != 1) {
      throw const FormatException('Unsupported sync plan schema.');
    }
    final planId = _string(json, 'planId');
    final generation = _string(json, 'generation');
    final operations = _list(json, 'operations').map((value) {
      if (value is! Map) {
        throw const FormatException('Plan operation must be an object.');
      }
      return _operationFromJson(Map<String, Object?>.from(value));
    }).toList(growable: false);
    final ids = <String>{};
    for (final operation in operations) {
      if (operation.planId != planId || operation.generation != generation) {
        throw const FormatException(
            'Plan operation scope does not match plan.');
      }
      if (!ids.add(operation.id)) {
        throw const FormatException('Plan contains duplicate operation IDs.');
      }
      if (operation.source != null &&
          operation.source!.path != operation.path) {
        throw const FormatException(
            'Plan source path does not match operation.');
      }
      if (operation.other != null && operation.other!.path != operation.path) {
        if (operation.kind != SyncOperationKind.conflict ||
            operation.preservePath == null ||
            operation.other!.path != operation.preservePath) {
          throw const FormatException(
              'Plan conflict path does not match operation.');
        }
      }
      if (operation.remoteBefore != null &&
          operation.remoteBefore!.path != operation.path) {
        throw const FormatException(
            'Plan remote-before path does not match operation.');
      }
      if (operation.kind == SyncOperationKind.conflict &&
          (operation.other == null ||
              operation.preservePath == null ||
              operation.sourceIsLocal == null ||
              operation.other!.path != operation.preservePath)) {
        throw const FormatException('Incomplete preserve-both operation.');
      }
    }
    return SyncPlan(
      planId: planId,
      generation: generation,
      remoteNamespace: _string(json, 'remoteNamespace'),
      deletionsSuppressed: _bool(json, 'deletionsSuppressed'),
      operations: operations,
    );
  }

  static Map<String, Object?> _operationToJson(SyncOperation operation) =>
      <String, Object?>{
        'id': operation.id,
        'kind': operation.kind.name,
        'path': operation.path.value,
        'planId': operation.planId,
        'generation': operation.generation,
        'source':
            operation.source == null ? null : _entryToJson(operation.source!),
        'other':
            operation.other == null ? null : _entryToJson(operation.other!),
        'remoteBefore': operation.remoteBefore == null
            ? null
            : _entryToJson(operation.remoteBefore!),
        'condition': _remoteConditionToJson(operation.condition),
        'metadataCondition':
            _remoteConditionToJson(operation.metadataCondition),
        'localCondition': _localConditionToJson(operation.localCondition),
        'preservePath': operation.preservePath?.value,
        'expectedLocalSha256': operation.expectedLocalSha256,
        'sourceIsLocal': operation.sourceIsLocal,
      };

  static SyncOperation _operationFromJson(Map<String, Object?> json) {
    final kind = _enumValue(SyncOperationKind.values, _string(json, 'kind'));
    final source = _entryFromJson(_mapOrNull(json['source']));
    final other = _entryFromJson(_mapOrNull(json['other']));
    final preserve = json['preservePath'];
    if (preserve != null && preserve is! String) {
      throw const FormatException('Invalid preserve path.');
    }
    final preservePath =
        preserve == null ? null : SyncPath.parse(preserve as String);
    return SyncOperation(
      id: _string(json, 'id'),
      kind: kind,
      path: SyncPath.parse(_string(json, 'path')),
      planId: _string(json, 'planId'),
      generation: _string(json, 'generation'),
      source: source,
      other: other,
      remoteBefore: _entryFromJson(_mapOrNull(json['remoteBefore'])),
      condition: _remoteConditionFromJson(_mapOrNull(json['condition'])),
      metadataCondition:
          _remoteConditionFromJson(_mapOrNull(json['metadataCondition'])),
      localCondition:
          _localConditionFromJson(_mapOrNull(json['localCondition'])),
      preservePath: preservePath,
      expectedLocalSha256: _nullableString(json, 'expectedLocalSha256'),
      sourceIsLocal: json['sourceIsLocal'] as bool?,
    );
  }

  static Map<String, Object?> _entryToJson(SyncEntry entry) =>
      <String, Object?>{
        'id': entry.id,
        'path': entry.path.value,
        'kind': entry.kind.name,
        'size': entry.size,
        'modifiedAtUtc': entry.modifiedAtUtc.toIso8601String(),
        'sha256': entry.sha256,
        'etag': entry.etag,
        'revision': entry.revision,
        'favorite': <String, Object?>{
          'value': entry.favorite.value,
          'lamport': entry.favorite.lamport,
          'deviceId': entry.favorite.deviceId,
        },
      };

  static SyncEntry? _entryFromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final favoriteMap = _map(json, 'favorite');
    final favoriteDevice = favoriteMap['deviceId'];
    if (favoriteDevice is! String) {
      throw const FormatException('Missing string: deviceId');
    }
    final favorite = FavoriteStamp(
      value: _bool(favoriteMap, 'value'),
      lamport: _int(favoriteMap, 'lamport'),
      // The initial local favorite stamp legitimately has an empty device ID;
      // the first local Lamport write supplies the installation identity.
      deviceId: favoriteDevice,
    );
    final kind = _enumValue(SyncEntryKind.values, _string(json, 'kind'));
    final path = SyncPath.parse(_string(json, 'path'));
    final modified = DateTime.tryParse(_string(json, 'modifiedAtUtc'));
    if (modified == null) throw const FormatException('Invalid entry time.');
    final id = _string(json, 'id');
    final revision = _int(json, 'revision');
    final etag = _nullableString(json, 'etag');
    final size = _int(json, 'size');
    return switch (kind) {
      SyncEntryKind.file => SyncEntry.file(
          id: id,
          path: path,
          size: size,
          modifiedAtUtc: modified,
          sha256: _string(json, 'sha256'),
          etag: etag,
          revision: revision,
          favorite: favorite,
        ),
      SyncEntryKind.directory => SyncEntry.directory(
          id: id,
          path: path,
          modifiedAtUtc: modified,
          etag: etag,
          revision: revision,
          favorite: favorite,
        ),
      SyncEntryKind.tombstone => SyncEntry.tombstone(
          id: id,
          path: path,
          modifiedAtUtc: modified,
          revision: revision,
          favorite: favorite,
        ),
    };
  }

  static Map<String, Object?>? _remoteConditionToJson(RemoteCondition? value) {
    if (value == null) return null;
    return switch (value) {
      CreateOnly() => <String, Object?>{'kind': 'create-only'},
      MatchEtag(:final etag) => <String, Object?>{
          'kind': 'match-etag',
          'etag': etag,
        },
      RemoteCondition() => throw const FormatException(
          'Unsupported remote condition in plan.',
        ),
    };
  }

  static RemoteCondition? _remoteConditionFromJson(
    Map<String, Object?>? json,
  ) {
    if (json == null) return null;
    return switch (_string(json, 'kind')) {
      'create-only' => const CreateOnly(),
      'match-etag' => MatchEtag(_string(json, 'etag')),
      _ => throw const FormatException('Unsupported remote condition.'),
    };
  }

  static Map<String, Object?>? _localConditionToJson(LocalCondition? value) {
    if (value == null) return null;
    return switch (value) {
      LocalCreateOnly() => <String, Object?>{'kind': 'create-only'},
      LocalMatchSha256(:final sha256) => <String, Object?>{
          'kind': 'match-sha256',
          'sha256': sha256,
        },
      LocalCondition() => throw const FormatException(
          'Unsupported local condition in plan.',
        ),
    };
  }

  static LocalCondition? _localConditionFromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    return switch (_string(json, 'kind')) {
      'create-only' => const LocalCreateOnly(),
      'match-sha256' => LocalMatchSha256(_string(json, 'sha256')),
      _ => throw const FormatException('Unsupported local condition.'),
    };
  }

  static Map<String, Object?>? _mapOrNull(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw const FormatException('Expected an object.');
    return Map<String, Object?>.from(value);
  }

  static Map<String, Object?> _map(Map<String, Object?> json, String key) {
    final value = json[key];
    final result = _mapOrNull(value);
    if (result == null) throw FormatException('Missing object: $key');
    return result;
  }

  static List<Object?> _list(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! List) throw FormatException('Missing list: $key');
    return List<Object?>.from(value);
  }

  static String _string(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing string: $key');
    }
    return value;
  }

  static String? _nullableString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('Invalid string: $key');
    return value;
  }

  static int _int(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! int) throw FormatException('Missing integer: $key');
    return value;
  }

  static bool _bool(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! bool) throw FormatException('Missing boolean: $key');
    return value;
  }

  static T _enumValue<T extends Enum>(List<T> values, String name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown enum value: $name');
  }
}
