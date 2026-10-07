import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import '../../app/design/theme_mode.dart';
import '../../app/localization/language.dart';
import '../../app/music/music_deletion.dart';
import '../../app/music/music_scan.dart';
import '../../app/music/music_scan_port.dart';
import '../../app/settings/settings_view_model.dart';
import '../../app/sync/sync_gate.dart';
import '../../app/sync/sync_status_view_model.dart';
import '../../data/broker_local_snapshot_provider.dart';
import 'music_deletion_service.dart';
import '../../data/catalog_recording_local_object_store.dart';
import '../../data/sync_tune_database.dart';
import '../../data/webdav_repository.dart';
import '../network/webdav_connection_checker.dart';
import '../network/windows_winrt_http_adapter.dart';
import '../platform/broker_capabilities.dart';
import '../platform/broker_credentials.dart';
import '../platform/broker_local_object_store.dart';
import '../platform/broker_music_scanner.dart';
import '../platform/broker_root_revoker.dart';
import '../platform/sync_notification_port.dart';
import '../runtime/foreground_sync_runtime.dart';
import '../runtime/sync_failure_message.dart';

/// The services needed before a sync can be opened. Production composition
/// leaves this bundle absent until local broker, remote compatibility and the
/// coordinator's durable stores are all available.
final class CompositionSyncServices {
  const CompositionSyncServices({
    required this.localSnapshots,
    required this.remoteSnapshots,
    required this.baseline,
    required this.local,
    required this.remote,
    required this.journal,
    required this.plans,
    this.capabilityCheck,
    this.remoteMusicImport,
  });

  final LocalSnapshotProvider localSnapshots;
  final RemoteSnapshotProvider remoteSnapshots;
  final BaselineStore baseline;
  final LocalObjectStore local;
  final RemoteRepository remote;
  final JournalStore journal;
  final PlanStore plans;
  final CompositionCapabilityCheck? capabilityCheck;
  final Future<void> Function(CancellationToken token)? remoteMusicImport;
}

typedef CompositionCapabilityCheck = Future<SyncGateState> Function(
  SyncRuntimeTarget target, {
  required CancellationToken token,
});

/// Evidence that the platform's real file-safety and recovery path has been
/// exercised for this target.  Broker capability strings are declarations;
/// they are intentionally insufficient to open the production sync gate.
abstract interface class CompositionRuntimeEvidenceGate {
  Future<bool> verify(
    SyncRuntimeTarget target, {
    required CancellationToken token,
  });
}

/// Mutable root/config identity shared by platform adapters and the runtime.
/// A root change emits before any new run can publish a result.
final class CompositionTargetPort implements SyncRuntimeTargetPort {
  CompositionTargetPort({String configEpoch = 'unconfigured'})
    : _configEpoch = configEpoch; // ignore: prefer_initializing_formals

  final StreamController<SyncRuntimeTarget?> _changes =
      StreamController<SyncRuntimeTarget?>.broadcast();
  SyncRuntimeTarget? _current;
  String _configEpoch;
  String _credentialEpoch = 'credential-initial';
  bool _closed = false;

  @override
  SyncRuntimeTarget? get current => _current;

  String get configEpoch => _configEpoch;

  String get credentialEpoch => _credentialEpoch;

  @override
  Stream<SyncRuntimeTarget?> get changes => _changes.stream;

  void setRoot(RootGrant? grant) {
    if (_closed) return;
    final next = grant == null
        ? null
        : SyncRuntimeTarget(
            rootToken: grant.token,
            rootGeneration: grant.generation,
            configEpoch: _configEpoch,
            credentialEpoch: _credentialEpoch,
          );
    if (_same(next, _current)) return;
    _current = next;
    _changes.add(next);
  }

  void setConfigEpoch(String value) {
    if (_closed) return;
    if (value == _configEpoch) return;
    _configEpoch = value;
    final current = _current;
    if (current == null) return;
    _current = SyncRuntimeTarget(
      rootToken: current.rootToken,
      rootGeneration: current.rootGeneration,
      configEpoch: value,
      credentialEpoch: _credentialEpoch,
    );
    _changes.add(_current);
  }

  void setCredentialEpoch(String value) {
    if (_closed) return;
    if (value == _credentialEpoch) return;
    _credentialEpoch = value;
    final current = _current;
    if (current == null) return;
    _current = SyncRuntimeTarget(
      rootToken: current.rootToken,
      rootGeneration: current.rootGeneration,
      configEpoch: _configEpoch,
      credentialEpoch: value,
    );
    _changes.add(_current);
  }

  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    return _changes.close();
  }

  bool _same(SyncRuntimeTarget? left, SyncRuntimeTarget? right) =>
      left?.identity == right?.identity;
}

/// A core coordinator adapter. It deliberately returns an unavailable gate
/// until the composition root supplies every local/remote/durable service.
final class CompositionConfirmedSyncRunner
    implements ConfirmedSyncRunner, ExistingRemoteMusicImporter {
  CompositionConfirmedSyncRunner({
    SyncCoordinator coordinator = const SyncCoordinator(),
    this.services,
  }) : _coordinator = coordinator; // ignore: prefer_initializing_formals

  final SyncCoordinator _coordinator;
  CompositionSyncServices? services;

  @override
  Future<void> importCloudMusic(
    SyncRuntimeTarget target, {
    required CancellationToken token,
  }) async {
    final importer = services?.remoteMusicImport;
    if (importer == null) {
      throw const SyncRuntimeNotReady('Cloud music import is unavailable.');
    }
    token.throwIfCancelled();
    await importer(token);
    token.throwIfCancelled();
  }

  @override
  Future<SyncGateState> check(
    SyncRuntimeTarget target, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final currentServices = services;
    if (currentServices == null) {
      return const SyncGateState.unavailable();
    }
    final capabilityCheck = currentServices.capabilityCheck;
    if (capabilityCheck == null) {
      return const SyncGateState.unavailable();
    }
    final result = await capabilityCheck(target, token: token);
    token.throwIfCancelled();
    return result;
  }

  @override
  Future<SyncRunResult> run(
    SyncRuntimeTarget target, {
    required String runToken,
    CancellationToken token = const NeverCancelled(),
  }) async {
    final currentServices = services;
    if (currentServices == null) {
      throw const SyncRuntimeNotReady('The sync service is not connected yet');
    }
    token.throwIfCancelled();
    final root = SyncRoot(
      target.rootToken,
      generation: target.rootGeneration,
      remoteNamespace: target.configEpoch,
    );
    final result = await _coordinator.run(
      root,
      planId: runToken,
      localSnapshots: currentServices.localSnapshots,
      remoteSnapshots: currentServices.remoteSnapshots,
      baseline: currentServices.baseline,
      local: currentServices.local,
      remote: currentServices.remote,
      journal: currentServices.journal,
      plans: currentServices.plans,
      token: token,
    );
    token.throwIfCancelled();
    // Keep the runtime's success contract explicit at this boundary too.
    result.requireConfirmed();
    if (currentServices.baseline is SyncTuneDatabase) {
      await (currentServices.baseline as SyncTuneDatabase).markDeletionTasksCompleted(
        rootId: root.storageKey,
        generation: root.generation,
        remoteNamespace: root.remoteNamespace,
      );
    }
    return result;
  }
}

/// Drift-backed preference storage. The setting table is app-private and
/// does not contain credentials.
final class DatabaseLanguagePreferencePort implements LanguagePreferencePort {
  const DatabaseLanguagePreferencePort(this.database);
  final SyncTuneDatabase database;

  @override
  Future<AppLanguage> load() async =>
      AppLanguage.fromCode(await database.loadSetting('language'));

  @override
  Future<void> save(AppLanguage language) =>
      database.saveSetting('language', language.code);
}

final class DatabaseThemePreferencePort implements ThemePreferencePort {
  const DatabaseThemePreferencePort(this.database);

  final SyncTuneDatabase database;

  @override
  Future<ThemeMode> load() async {
    final value = await database.loadSetting('themeMode');
    if (value == null) return ThemeMode.system;
    try {
      return ThemeMode.values.byName(value);
    } catch (_) {
      return ThemeMode.system;
    }
  }

  @override
  Future<void> save(ThemeMode mode) =>
      database.saveSetting('themeMode', mode.name);
}

/// Persists non-secret WebDAV settings in the private database and delegates
/// the password to the platform credential broker. The persisted pointer is
/// an opaque, versioned account derived from a lowercase identity digest, so
/// broker key normalization cannot change a case-sensitive username and a
/// failed DB commit cannot replace the active secret. The raw username
/// remains available to the eventual Basic Auth client through the settings.
final class DatabaseWebDavSettingsPort
    implements
        WebDavSettingsPort,
        WebDavSettingsLoader,
        WebDavSettingsWarningPort {
  DatabaseWebDavSettingsPort({
    required this.database,
    required this.credentials,
    required this.onNamespaceChanged,
    this.onCredentialEpochChanged,
    this.onCredentialCleanupFailed,
  });

  static const credentialService = 'synctune-webdav-v1';

  final SyncTuneDatabase database;
  final BrokerCredentialStore credentials;
  final ValueChanged<String> onNamespaceChanged;
  final ValueChanged<String>? onCredentialEpochChanged;
  final ValueChanged<String>? onCredentialCleanupFailed;
  Future<void> _writeQueue = Future<void>.value();
  // Loads may be suspended in the platform vault while a later save commits.
  // Keep both generations so stale loads cannot publish callbacks.
  int _mutationGeneration = 0;
  int _loadGeneration = 0;
  String? _warning;

  @override
  String? takeWarning() {
    final warning = _warning;
    _warning = null;
    return warning;
  }

  @override
  Future<WebDavSettings> load() async {
    final loadGeneration = ++_loadGeneration;
    final mutationGeneration = _mutationGeneration;
    final stored = await database.loadSetting(_connectionKey);
    var endpoint = '';
    var username = '';
    var credentialEpoch = '';
    var credentialAccount = '';
    var credentialAccountPresent = false;
    var decodedRecord = false;
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is Map) {
          decodedRecord = true;
          endpoint = decoded['endpoint']?.toString() ?? '';
          username = decoded['username']?.toString() ?? '';
          credentialEpoch = decoded['credentialEpoch']?.toString() ?? '';
          credentialAccountPresent = decoded.containsKey('credentialAccount');
          credentialAccount = decoded['credentialAccount']?.toString() ?? '';
        }
      } catch (_) {
        // Fall through to the legacy keys below.
      }
    }
    if (!decodedRecord) {
      endpoint = await database.loadSetting(_legacyEndpointKey) ?? '';
      username = await database.loadSetting(_legacyUsernameKey) ?? '';
    }
    endpoint = canonicalWebDavEndpoint(endpoint) ?? endpoint.trim();
    // A missing pointer is the legacy format and may derive its stable
    // account. An explicit empty pointer means the user cleared the secret;
    // never resurrect that legacy account.
    if (!credentialAccountPresent &&
        (endpoint.isNotEmpty || username.isNotEmpty)) {
      // Legacy records used a stable identity as the broker account. New
      // writes use a versioned opaque pointer to make DB commits atomic.
      credentialAccount = credentialAccountFor(endpoint, username);
    }
    var password = '';
    if (credentialAccount.isNotEmpty) {
      try {
        password =
            await credentials.read(
              service: credentialService,
              account: credentialAccount,
            ) ??
            '';
      } catch (_) {
        // Keep the non-secret fields restorable even when the platform vault
        // is temporarily unavailable. A subsequent save reports that error.
      }
    }
    if (_isCurrentLoad(loadGeneration, mutationGeneration)) {
      onNamespaceChanged(namespaceFor(endpoint, username));
      onCredentialEpochChanged?.call(
        credentialEpoch.isEmpty
            ? namespaceFor(endpoint, username)
            : credentialEpoch,
      );
    }
    return WebDavSettings(
      endpoint: endpoint,
      username: username,
      password: password,
      credentialEpoch: credentialEpoch,
      credentialAccount: credentialAccount,
      credentialAccountPresent: credentialAccountPresent,
    );
  }

  @override
  Future<void> save(WebDavSettings settings) {
    // Invalidate loads that are already reading the database or vault. The
    // queued save remains independent of those reads.
    _mutationGeneration++;
    final operation = _writeQueue.then((_) => _save(settings));
    // Keep the queue alive after an expected broker/database error so a
    // subsequent user save still executes in call order.
    _writeQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _save(WebDavSettings settings) async {
    final endpoint = canonicalWebDavEndpoint(settings.endpoint);
    if (endpoint == null) {
      throw const FormatException('Invalid HTTPS WebDAV endpoint');
    }
    final username = settings.username;
    final old = await _loadConnectionRecord();
    final oldEndpoint = old.endpoint;
    final oldUsername = old.username;
    final oldAccount = old.credentialAccount.isNotEmpty
        ? old.credentialAccount
        : old.credentialAccountPresent
        ? null
        : oldEndpoint.isEmpty && oldUsername.isEmpty
        ? null
        : credentialAccountFor(oldEndpoint, oldUsername);
    final nextCredentialEpoch = _newCredentialEpoch();
    final sameIdentity = oldEndpoint == endpoint && oldUsername == username;
    String? nextAccount;

    // Store a new versioned secret first. The active pointer still references
    // the old secret until the database commit below succeeds.
    if (settings.password.isNotEmpty) {
      nextAccount = _versionedCredentialAccount(endpoint, username);
      await credentials.save(
        service: credentialService,
        account: nextAccount,
        secret: settings.password,
      );
    } else if (settings.clearPassword) {
      nextAccount = null;
    } else if (sameIdentity) {
      nextAccount = oldAccount;
    } else if (oldAccount != null) {
      throw const FormatException(
        'Changing WebDAV account requires a new password or explicit clear.',
      );
    }
    try {
      await database.saveSetting(
        _connectionKey,
        jsonEncode(<String, String>{
          'endpoint': endpoint,
          'username': username,
          'credentialEpoch': nextCredentialEpoch,
          'credentialAccount': nextAccount ?? '',
        }),
      );
    } catch (_) {
      // A failed commit leaves the old pointer and secret active. Best-effort
      // cleanup removes only the unreferenced secret staged by this attempt.
      if (nextAccount != null && nextAccount != oldAccount) {
        try {
          await credentials.delete(
            service: credentialService,
            account: nextAccount,
          );
        } catch (_) {}
      }
      rethrow;
    }

    // The new pointer is durable now. This also invalidates a load that began
    // after save() was called but before the database commit completed.
    _mutationGeneration++;

    // Publish every durable commit in queue order. A later save may fail
    // after this one commits; suppressing this callback by invocation order
    // would leave the runtime pointing at the previous identity.
    _publishCommitted(
      endpoint: endpoint,
      username: username,
      credentialEpoch: nextCredentialEpoch,
    );

    // The new pointer is active now. Retiring the old secret is deliberately
    // best effort: cleanup failure must not roll back a committed setting.
    if (oldAccount != null && oldAccount != nextAccount) {
      try {
        await credentials.delete(
          service: credentialService,
          account: oldAccount,
        );
      } catch (_) {
        _warning = 'Old WebDAV credential cleanup failed. The current settings remain active.';
        try {
          onCredentialCleanupFailed?.call(
            'Old WebDAV credential cleanup failed. The current settings remain active.',
          );
        } catch (_) {
          // Cleanup reporting is advisory and must not turn a committed
          // setting into a failed save.
        }
      }
    }
  }

  void _publishCommitted({
    required String endpoint,
    required String username,
    required String credentialEpoch,
  }) {
    try {
      onNamespaceChanged(namespaceFor(endpoint, username));
    } catch (_) {
      _warning ??=
          'Settings saved, but the runtime sync identity could not be updated.';
    }
    try {
      onCredentialEpochChanged?.call(credentialEpoch);
    } catch (_) {
      _warning ??= 'Settings saved, but the runtime credential version could not be updated.';
    }
  }

  bool _isCurrentLoad(int loadGeneration, int mutationGeneration) =>
      loadGeneration == _loadGeneration &&
      mutationGeneration == _mutationGeneration;

  Future<_WebDavConnectionRecord> _loadConnectionRecord() async {
    final stored = await database.loadSetting(_connectionKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is Map) {
          final endpoint =
              canonicalWebDavEndpoint(decoded['endpoint']?.toString() ?? '') ??
              (decoded['endpoint']?.toString() ?? '').trim();
          return _WebDavConnectionRecord(
            endpoint: endpoint,
            username: decoded['username']?.toString() ?? '',
            credentialAccount: decoded['credentialAccount']?.toString() ?? '',
            credentialAccountPresent: decoded.containsKey('credentialAccount'),
          );
        }
      } catch (_) {
        // Use the legacy fallback below.
      }
    }
    return _WebDavConnectionRecord(
      endpoint:
          canonicalWebDavEndpoint(
            await database.loadSetting(_legacyEndpointKey) ?? '',
          ) ??
          '',
      username: await database.loadSetting(_legacyUsernameKey) ?? '',
      credentialAccount: '',
      credentialAccountPresent: false,
    );
  }

  static String _versionedCredentialAccount(String endpoint, String username) {
    final nonce = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final suffix = nonce
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${credentialAccountFor(endpoint, username)}-$suffix';
  }

  String _newCredentialEpoch() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    return 'credential-${bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static String credentialAccountFor(String endpoint, String username) {
    final canonical = canonicalWebDavEndpoint(endpoint) ?? endpoint.trim();
    final material = '$canonical\u0000$username';
    return 'account-${sha256.convert(utf8.encode(material))}';
  }

  static String namespaceFor(String endpoint, String username) {
    final canonical = canonicalWebDavEndpoint(endpoint) ?? endpoint.trim();
    if (canonical.isEmpty && username.isEmpty) return 'unconfigured';
    final material = '$canonical\u0000$username';
    return 'webdav-${sha256.convert(utf8.encode(material))}';
  }

  static const _connectionKey = 'webdav.connection';
  static const _legacyEndpointKey = 'webdav.endpoint';
  static const _legacyUsernameKey = 'webdav.username';
}

final class _WebDavConnectionRecord {
  const _WebDavConnectionRecord({
    required this.endpoint,
    required this.username,
    required this.credentialAccount,
    required this.credentialAccountPresent,
  });

  final String endpoint;
  final String username;
  final String credentialAccount;
  final bool credentialAccountPresent;
}

/// Favorite adapter over the durable Drift table. IDs are the same catalog
/// UUIDs used by core snapshots, so favorite metadata participates in the
/// coordinator's Lamport/device merge instead of becoming a UI-only marker.
final class DatabaseMusicFavoritesPort implements MusicFavoritesPort {
  DatabaseMusicFavoritesPort({
    required this.database,
    required this.configEpoch,
  });

  final SyncTuneDatabase database;
  final String Function() configEpoch;

  @override
  Future<Set<String>> loadFavorites(RootGrant grant) async {
    final root = SyncRoot(
      grant.token,
      generation: grant.generation,
      remoteNamespace: configEpoch(),
    );
    final catalogRows = await database
        .customSelect(
          'SELECT entry_id FROM local_catalog WHERE root_id = ? AND generation = ?',
          variables: [
            Variable.withString(root.storageKey),
            Variable.withString(root.generation),
          ],
        )
        .get();
    final catalogIds = catalogRows
        .map((row) => row.read<String>('entry_id'))
        .toSet();
    if (catalogIds.isEmpty) return <String>{};
    final rows = await database.watchFavorites().first;
    return rows
        .where((row) => row.value && catalogIds.contains(row.entryId))
        .map((row) => row.entryId)
        .toSet();
  }

  @override
  Future<void> setFavorite({
    required RootGrant grant,
    required MusicTrack track,
    required bool value,
  }) {
    final id = track.id;
    if (id == null || id.isEmpty) {
      return Future<void>.error(
        StateError('The scan entry has no stable favorites identifier'),
      );
    }
    return _save(entryId: id, relativePath: track.relativePath, value: value);
  }

  Future<void> _save({
    required String entryId,
    required String relativePath,
    required bool value,
  }) async {
    final device = await database.loadOrCreateDeviceId();
    final lamport = await database.nextLamport();
    await database.saveFavorite(
      entryId: entryId,
      relativePath: relativePath,
      value: value,
      lamport: lamport,
      deviceId: device,
    );
  }
}

/// Adds the same catalog UUID used by [BrokerLocalSnapshotProvider] to the
/// lightweight music list when the native scanner only supplies paths.
final class CatalogEnrichingMusicScanner implements MusicScannerPort {
  const CatalogEnrichingMusicScanner({
    required this.delegate,
    required this.catalog,
    required this.configEpoch,
  });

  final MusicScannerPort delegate;
  final SyncTuneDatabase catalog;
  final String Function() configEpoch;

  @override
  Future<Map<Object?, Object?>> scan(RootGrant grant) async {
    final response = await delegate.scan(grant);
    final rawItems = response['items'];
    if (rawItems is! List) return response;
    final root = SyncRoot(
      grant.token,
      generation: grant.generation,
      remoteNamespace: configEpoch(),
    );
    final enriched = <Object?>[];
    for (final raw in rawItems) {
      if (raw is! Map) {
        enriched.add(raw);
        continue;
      }
      final item = Map<Object?, Object?>.from(raw);
      final path = item['relativePath']?.toString() ?? '';
      final existing = item['id']?.toString();
      try {
        final parsed = SyncPath.parse(path);
        if (existing == null || existing.isEmpty) {
          item['id'] = await catalog.ensureCatalogEntryId(
            root,
            parsed,
          );
        }
        if (item['sha256'] == null) {
          final entry = await catalog.loadCatalogEntry(root, parsed);
          if (entry?.sha256 != null && !entry!.isDeleted) {
            item['sha256'] = entry.sha256;
          }
        }
      } on FormatException {
        // MusicScanController retains its normal malformed-item error.
      }
      enriched.add(item);
    }
    return <Object?, Object?>{...response, 'items': enriched};
  }
}

/// Adapts the UI scanner's root-shaped request to the stricter snapshot
/// scanner port. The native broker receives only the opaque token and
/// generation; cancellation is checked around the platform boundary.
final class _BrokerSnapshotScanPort implements BrokerLocalScanPort {
  const _BrokerSnapshotScanPort({required this.scanner});

  final BrokerMusicScanner scanner;

  @override
  Future<Map<Object?, Object?>> scan(
    BrokerRoot root, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final result = await scanner.scan(
      RootGrant(path: '', token: root.token, generation: root.generation),
    );
    token.throwIfCancelled();
    return result;
  }
}

/// Creates an authenticated WebDAV repository only after the endpoint and
/// protected credential have been read. The repository itself remains a
/// data-layer object; the composition root owns credential materialization.
/// This public lifecycle contract lets the composition own the transport
/// without exposing the private WebDAV implementation type.
abstract interface class CompositionWebDavClientLifecycle {
  Future<void> dispose();
}

/// Lifecycle owned by the composition root for the configured WebDAV client.
///
/// The public surface intentionally exposes only probes and disposal. The
/// repository lease remains private so callers cannot bypass the target and
/// credential checks performed here.
final class CompositionWebDavClient
    implements CompositionWebDavClientLifecycle {
  CompositionWebDavClient({
    required this.settings,
    required this.credentials,
    required this.targets,
    this.dioFactory,
    this.transportChannel,
    this.root,
  });

  final WebDavSettingsLoader settings;
  final BrokerCredentialStore credentials;
  final CompositionTargetPort targets;

  /// Test-only transport seam. Production leaves this null and uses the
  /// platform transport selected below, while composition recovery tests can
  /// delay a response without opening a real network connection.
  final Dio Function(BaseOptions options)? dioFactory;
  final BrokerMethodChannel? transportChannel;
  final BrokerRootPort? root;
  final Map<String, _WebDavClientEntry> _entries =
      <String, _WebDavClientEntry>{};
  bool _disposed = false;

  /// Reads the current settings and credentials without issuing a network
  /// request. This is also the production readiness check used by formal
  /// composition tests: an explicitly empty credential pointer is a cleared
  /// secret, so it must fail closed instead of falling back to a legacy key.
  Future<void> ensureCredentials({required CancellationToken token}) async {
    final lease = await _lease(token: token);
    await lease.release();
  }

  Future<_WebDavLease> _lease({required CancellationToken token}) async {
    if (_disposed) throw const SyncCancelled();
    token.throwIfCancelled();
    final initialIdentity = targets.current?.identity;
    if (initialIdentity == null) {
      throw const SyncRuntimeNotReady('Sync root folder access required');
    }
    final current = await settings.load();
    token.throwIfCancelled();
    _ensureTarget(initialIdentity);
    final endpoint = canonicalWebDavEndpoint(current.endpoint);
    if (endpoint == null) {
      throw const SyncRuntimeNotReady('The WebDAV URL is not configured');
    }
    var password = current.password;
    if (current.username.isNotEmpty && password.isEmpty) {
      final account = current.credentialAccount.isNotEmpty
          ? current.credentialAccount
          : current.credentialAccountPresent
          ? null
          : DatabaseWebDavSettingsPort.credentialAccountFor(
              endpoint,
              current.username,
            );
      if (account == null) {
        throw const SyncRuntimeNotReady(
          'WebDAV credentials are not configured',
        );
      }
      password =
          await credentials.read(
            service: DatabaseWebDavSettingsPort.credentialService,
            account: account,
          ) ??
          '';
    }
    token.throwIfCancelled();
    _ensureTarget(initialIdentity);
    if (current.username.isNotEmpty && password.isEmpty) {
      throw const SyncRuntimeNotReady('WebDAV credentials are not configured');
    }
    final credentialEpoch = current.credentialEpoch.isEmpty
        ? DatabaseWebDavSettingsPort.namespaceFor(endpoint, current.username)
        : current.credentialEpoch;
    final key = '$endpoint\u0000${current.username}\u0000$credentialEpoch';
    for (final entry in _entries.values.toList()) {
      if (entry.key == key) continue;
      entry.retired = true;
      if (entry.leases == 0) {
        entry.dio.close(force: true);
        _entries.remove(entry.key);
      }
    }
    final existing = _entries[key];
    if (existing != null) {
      existing.leases++;
      return _WebDavLease(this, existing);
    }
    final headers = <String, String>{};
    if (current.username.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('${current.username}:$password'))}';
    }
    final entry = _WebDavClientEntry(
      dio:
          dioFactory?.call(BaseOptions(headers: headers)) ??
          _createProductionDio(headers),
      key: key,
      baseUri: Uri.parse(endpoint),
    );
    _entries[key] = entry;
    entry.leases++;
    return _WebDavLease(this, entry);
  }

  Dio _createProductionDio(Map<String, String> headers) {
    final dio = Dio(BaseOptions(headers: headers));
    if (Platform.isWindows && transportChannel != null) {
      dio.httpClientAdapter = WindowsWinRtHttpAdapter(
        channel: transportChannel!,
        root: root,
      );
    }
    return dio;
  }

  void _ensureTarget(String identity) {
    if (_disposed || targets.current?.identity != identity) {
      throw const SyncCancelled();
    }
  }

  Future<void> probe({required CancellationToken token}) async {
    final lease = await _lease(token: token);
    try {
      await lease.repository.propfindRoot(token: token);
    } finally {
      await lease.release();
    }
  }

  Future<void> importCloudMusic({required CancellationToken token}) async {
    final lease = await _lease(token: token);
    try {
      await WebDavRemoteSnapshotProvider(repository: lease.repository)
          .importExistingMusic(token: token);
    } finally {
      await lease.release();
    }
  }

  Future<void> _release(_WebDavClientEntry entry) async {
    if (entry.leases > 0) entry.leases--;
    if (entry.retired && entry.leases == 0) {
      _entries.remove(entry.key);
      entry.dio.close(force: true);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.values.toList()) {
      entry.retired = true;
      if (entry.leases == 0) {
        entry.dio.close(force: true);
        _entries.remove(entry.key);
      }
    }
  }
}

final class _WebDavClientEntry {
  _WebDavClientEntry({
    required this.dio,
    required this.key,
    required this.baseUri,
  });

  final Dio dio;
  final String key;
  final Uri baseUri;
  int leases = 0;
  bool retired = false;

  WebDavRepository get repository =>
      WebDavRepository(dio: dio, baseUri: baseUri);
}

final class _WebDavLease {
  _WebDavLease(this.client, this.entry);

  final CompositionWebDavClient client;
  final _WebDavClientEntry entry;
  bool _released = false;

  WebDavRepository get repository => entry.repository;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await client._release(entry);
  }
}

Stream<List<int>> _releaseAfter(
  Stream<List<int>> stream,
  _WebDavLease lease,
) async* {
  try {
    yield* stream;
  } finally {
    await lease.release();
  }
}

/// Remote repository wrapper used by the composition root. It owns the
/// client lease for every operation and forwards the optional recovery
/// capability only after the active root and remote namespace are checked.
final class CompositionRemoteRepository
    implements RemoteRepository, RemotePlanRecovery {
  const CompositionRemoteRepository(this.client);

  final CompositionWebDavClient client;

  Future<T> _with<T>(
    CancellationToken token,
    Future<T> Function(WebDavRepository repository) action,
  ) async {
    final lease = await client._lease(token: token);
    try {
      token.throwIfCancelled();
      return await action(lease.repository);
    } finally {
      await lease.release();
    }
  }

  @override
  Future<Set<String>> recoverPendingPlan(
    SyncRoot root,
    SyncPlan plan, {
    required Iterable<JournalRecord> journal,
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final initialIdentity = client.targets.current?.identity;
    _ensureRecoveryRoot(root, initialIdentity);
    final lease = await client._lease(token: token);
    try {
      token.throwIfCancelled();
      if (client.targets.current?.identity != initialIdentity) {
        throw const SyncCancelled();
      }
      final recovered = await lease.repository.recoverPendingPlan(
        root,
        plan,
        journal: journal,
        token: token,
      );
      token.throwIfCancelled();
      _ensureRecoveryRoot(root, initialIdentity);
      return recovered;
    } finally {
      await lease.release();
    }
  }

  void _ensureRecoveryRoot(SyncRoot root, String? initialIdentity) {
    final target = client.targets.current;
    if (initialIdentity == null ||
        target == null ||
        target.identity != initialIdentity ||
        target.rootToken != root.id ||
        target.rootGeneration != root.generation ||
        target.configEpoch != root.remoteNamespace) {
      throw const NeedsRescan('remote recovery scope changed');
    }
  }

  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    final lease = await client._lease(token: token);
    try {
      final stream = await lease.repository.read(path, token: token);
      return _releaseAfter(stream, lease);
    } catch (_) {
      await lease.release();
      rethrow;
    }
  }

  @override
  Future<String> put(
    SyncPath path,
    Stream<List<int>> content, {
    required SyncEntry entry,
    required RemoteCondition condition,
    required RemoteCondition metadataCondition,
    CancellationToken token = const NeverCancelled(),
  }) => _with(
    token,
    (repository) => repository.put(
      path,
      content,
      entry: entry,
      condition: condition,
      metadataCondition: metadataCondition,
      token: token,
    ),
  );

  @override
  Future<void> delete(
    SyncPath path, {
    required MatchEtag condition,
    SyncEntry? tombstone,
    RemoteCondition? metadataCondition,
    CancellationToken token = const NeverCancelled(),
  }) => _with(
    token,
    (repository) => repository.delete(
      path,
      condition: condition,
      tombstone: tombstone,
      metadataCondition: metadataCondition,
      token: token,
    ),
  );

  @override
  Future<void> putTombstone(
    SyncPath path, {
    required SyncEntry tombstone,
    required RemoteCondition metadataCondition,
    CancellationToken token = const NeverCancelled(),
  }) => _with(
    token,
    (repository) => repository.putTombstone(
      path,
      tombstone: tombstone,
      metadataCondition: metadataCondition,
      token: token,
    ),
  );

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    required RemoteCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) => _with(
    token,
    (repository) => repository.updateFavorite(
      path,
      stamp,
      condition: condition,
      token: token,
    ),
  );
}

/// Reads the evidence written by the platform diagnostics route and checks it
/// against the currently running packaged process.  The evidence file is only
/// an audit trail; the native broker capability response is queried again so
/// a stale or edited record cannot widen the platform contract.
final class PersistedRuntimeEvidenceGate
    implements CompositionRuntimeEvidenceGate {
  /// The production WebDAV client uses the same bounded WinRT transport as
  /// the Windows probe. Android and other native targets retain Dio's
  /// dart:io transport.
  static String get productionHttpsTransport =>
      Platform.isWindows ? 'dio_winrt_http' : 'dart_io_http_client';

  const PersistedRuntimeEvidenceGate({
    required this.channel,
    required this.root,
  });

  final BrokerMethodChannel channel;
  final BrokerRootPort root;

  @override
  Future<bool> verify(
    SyncRuntimeTarget target, {
    required CancellationToken token,
  }) async {
    token.throwIfCancelled();
    if (!_sameRoot(root.current, target)) return false;
    final process = _asMap(await channel.invokeMethod<Object?>('processInfo'));
    if (!_sameRoot(root.current, target)) return false;
    if (process == null) return false;
    final processPid = _text(process['pid']);
    final packageFamily = _text(process['packageFamily']);
    final packageVersion = _text(process['packageVersion']);
    if (processPid == null ||
        packageFamily == null ||
        packageVersion == null ||
        process['appContainer'] != 'true') {
      return false;
    }
    token.throwIfCancelled();
    final databasePath = await channel.invokeMethod<String>(
      'privateDatabasePath',
    );
    if (!_sameRoot(root.current, target)) return false;
    if (databasePath == null || databasePath.isEmpty) return false;
    final directory = Directory(File(databasePath).parent.path);
    if (!await directory.exists()) return false;
    final currentFile = File(
      '${directory.path}${Platform.pathSeparator}'
      'synctune-probe-results-$processPid.json',
    );
    final current = await currentFile.exists()
        ? await _readEvidence(currentFile)
        : null;
    if (!_sameRoot(root.current, target)) return false;

    final history = <Map<String, Object?>>[];
    await for (final entity in directory.list()) {
      token.throwIfCancelled();
      if (entity is! File ||
          !RegExp(r'synctune-probe-results-\d+\.json$')
              .hasMatch(entity.uri.pathSegments.last)) {
        continue;
      }
      final record = await _readEvidence(entity);
      if (record != null) history.add(record);
    }
    if (!_sameRoot(root.current, target)) return false;

    final liveRestore = _asMap(
      await channel.invokeMethod<Object?>('restoreFolder'),
    );
    if (!_sameRoot(root.current, target)) return false;
    if (liveRestore == null ||
        liveRestore['status'] != 'ok' ||
        liveRestore['fileIo'] != 'ok' ||
        _text(liveRestore['token']) != target.rootToken ||
        _text(liveRestore['generation']) != target.rootGeneration) {
      return false;
    }

    final rawCapabilities = await channel.invokeMethod<Object?>(
      'brokerCapabilities',
    );
    final capabilities = BrokerCapabilities.fromResponse(rawCapabilities);
    token.throwIfCancelled();
    if (!_sameRoot(root.current, target)) return false;
    final candidates = <Map<String, Object?>>[?current, ...history.reversed];
    for (final candidate in candidates) {
      if (!validate(
        currentProcess: process,
        currentEvidence: candidate,
        history: history,
        capabilities: capabilities,
        rootToken: target.rootToken,
        rootGeneration: target.rootGeneration,
      )) {
        continue;
      }
      final startup = _asMap(candidate['startup']);
      final restored = _asMap(startup?['folderRestore']);
      if (_sameRestore(restored, liveRestore)) return true;
    }
    return false;
  }

  /// Pure validation for acceptance tests and offline evidence review.
  static bool validate({
    required Map<String, Object?> currentProcess,
    required Map<String, Object?> currentEvidence,
    required Iterable<Map<String, Object?>> history,
    required BrokerCapabilities capabilities,
    required String rootToken,
    required String rootGeneration,
    String? requiredHttpsTransport,
  }) {
    final expectedHttpsTransport =
        requiredHttpsTransport ?? productionHttpsTransport;
    final processPid = _text(currentProcess['pid']);
    final packageFamily = _text(currentProcess['packageFamily']);
    final packageVersion = _text(currentProcess['packageVersion']);
    if (processPid == null ||
        packageFamily == null ||
        packageVersion == null ||
        currentProcess['appContainer'] != 'true') {
      return false;
    }
    final startup = _asMap(currentEvidence['startup']);
    final startupProcess = _asMap(startup?['process']);
    if (currentEvidence['schema'] != 1 ||
        startup == null ||
        startupProcess == null ||
        _text(startupProcess['pid']) == null ||
        startupProcess['appContainer'] != 'true' ||
        _text(startupProcess['packageFamily']) != packageFamily ||
        _text(startupProcess['packageVersion']) != packageVersion) {
      return false;
    }

    final sqlite = _asMap(startup['sqlite']);
    if (sqlite?['status'] != 'passed' || sqlite?['restartCheck'] != true) {
      return false;
    }
    final https = _asMap(startup['https']);
    final httpStatus = https?['httpStatus'];
    if (https?['status'] != 'passed' ||
        httpStatus is! num ||
        httpStatus < 200 ||
        httpStatus >= 300) {
      return false;
    }
    if (https?['transport'] != expectedHttpsTransport) {
      return false;
    }
    final credential = _asMap(startup['credential']);
    if (credential?['status'] != 'ok' ||
        credential?['restartCheck'] != 'ok' ||
        credential?['appContainer'] != 'true') {
      return false;
    }
    final restored = _asMap(startup['folderRestore']);
    final startupPid = _text(startupProcess['pid']);
    final restoredContent = _text(
      restored?['restoredContent'] ?? restored?['markerContent'],
    );
    if (restored?['status'] != 'ok' ||
        restored?['fileIo'] != 'ok' ||
        _text(restored?['restoredPid']) != startupPid ||
        _text(restored?['token']) != rootToken ||
        _text(restored?['generation']) != rootGeneration ||
        _text(restored?['marker']) == null ||
        restoredContent == null) {
      return false;
    }
    final recordedCapabilities = _asMap(startup['brokerCapabilities']);
    if (recordedCapabilities == null ||
        recordedCapabilities['status'] != 'ok' ||
        !_sameCapabilities(recordedCapabilities, capabilities)) {
      return false;
    }

    var hasFolderPick = false;
    var hasDifferentPid = false;
    for (final record in history) {
      final recordStartup = _asMap(record['startup']);
      final recordProcess = _asMap(recordStartup?['process']);
      if (record['schema'] != 1 ||
          recordProcess == null ||
          recordProcess['appContainer'] != 'true' ||
          _text(recordProcess['packageFamily']) != packageFamily ||
          _text(recordProcess['packageVersion']) == null) {
        continue;
      }
      final recordPid = _text(recordProcess['pid']);
      final folderPick = _asMap(record['folderPick']);
      if (folderPick?['status'] != 'ok' ||
          folderPick?['reopen'] != 'ok' ||
          folderPick?['fileIo'] != 'ok' ||
          _text(folderPick?['token']) != rootToken ||
          _text(folderPick?['generation']) != rootGeneration ||
          _text(folderPick?['marker']) != _text(restored?['marker']) ||
          _text(folderPick?['markerContent']) != restoredContent) {
        continue;
      }
      hasFolderPick = true;
      if (recordPid != null && recordPid != startupPid) {
        hasDifferentPid = true;
      }
    }
    return hasFolderPick && hasDifferentPid;
  }

  static Future<Map<String, Object?>?> _readEvidence(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      return _asMap(decoded);
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?>? _asMap(Object? value) {
    if (value is! Map) return null;
    return <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }

  static String? _text(Object? value) {
    if (value == null) return null;
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  static bool _sameCapabilities(
    Map<String, Object?> recorded,
    BrokerCapabilities live,
  ) {
    return recorded['platform'] == live.platform &&
        recorded['credentials'] == live.credentials &&
        recorded['staging'] == live.staging &&
        recorded['atomicCreate'] == live.atomicCreate &&
        recorded['conditionalReplace'] == live.conditionalReplace &&
        recorded['conditionalDelete'] == live.conditionalDelete &&
        recorded['temporaryPermission'] == live.temporaryPermission;
  }

  static bool _sameRestore(
    Map<String, Object?>? recorded,
    Map<String, Object?> live,
  ) {
    final recordedContent = _text(
      recorded?['restoredContent'] ?? recorded?['markerContent'],
    );
    final liveContent = _text(live['restoredContent'] ?? live['markerContent']);
    return recorded?['status'] == 'ok' &&
        recorded?['fileIo'] == 'ok' &&
        _text(recorded?['token']) == _text(live['token']) &&
        _text(recorded?['generation']) == _text(live['generation']) &&
        _text(recorded?['marker']) == _text(live['marker']) &&
        recordedContent == liveContent;
  }

  static bool _sameRoot(BrokerRoot? current, SyncRuntimeTarget target) {
    return current?.token == target.rootToken &&
        current?.generation == target.rootGeneration;
  }
}

final class _ConfiguredRemoteSnapshotProvider
    implements RemoteSnapshotProvider {
  const _ConfiguredRemoteSnapshotProvider(this.client);

  final CompositionWebDavClient client;

  @override
  Future<RemoteSnapshot> capture(
    SyncRoot root, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    final lease = await client._lease(token: token);
    try {
      return await WebDavRemoteSnapshotProvider(repository: lease.repository)
          .capture(root, token: token);
    } finally {
      await lease.release();
    }
  }
}

final class _ProductionCapabilityCheck {
  const _ProductionCapabilityCheck({
    required this.channel,
    required this.root,
    required this.client,
    this.evidenceGate,
  });

  final BrokerMethodChannel channel;
  final BrokerRootPort root;
  final CompositionWebDavClient client;
  final CompositionRuntimeEvidenceGate? evidenceGate;

  Future<SyncGateState> call(
    SyncRuntimeTarget target, {
    required CancellationToken token,
  }) async {
    token.throwIfCancelled();
    final active = root.current;
    if (active == null ||
        active.token != target.rootToken ||
        active.generation != target.rootGeneration) {
      return const SyncGateState(
        status: SyncGateStatus.unavailable,
        title: 'Sync waiting for authorization',
        message: 'The authorized folder has changed. Confirm folder access again before syncing.',
      );
    }
    late final BrokerCapabilities capabilities;
    try {
      capabilities = await MethodChannelBrokerCapabilities(channel: channel)
          .read();
    } on SyncCancelled {
      rethrow;
    } catch (_) {
      return const SyncGateState(
        status: SyncGateStatus.unavailable,
        title: 'Platform requirements not met',
        message: 'Platform file safety capabilities are unavailable. Sync is currently unavailable.',
      );
    }
    token.throwIfCancelled();
    if (!capabilities.canVerifiedCreate ||
        !capabilities.canVerifiedBackupReplace ||
        !capabilities.canVerifiedBackupDelete) {
      return const SyncGateState(
        status: SyncGateStatus.unavailable,
        title: 'Platform requirements not met',
        message: 'The platform cannot verify, preserve, and recover local file changes. Sync is currently unavailable.',
      );
    }
    try {
      await client.probe(token: token);
      token.throwIfCancelled();
      return const SyncGateState(
        status: SyncGateStatus.ready,
        title: 'Ready to sync',
        message: 'Folder access, the remote connection, and safety requirements are verified.',
      );
    } on SyncCancelled {
      rethrow;
    } catch (error) {
      return SyncGateState(
        status: SyncGateStatus.unavailable,
        title: 'Remote connection not verified',
        message: error is SyncRuntimeNotReady
            ? error.message
            : syncFailureMessage(error),
      );
    }
  }
}

/// Production dependency bundle. It binds platform scanner/revocation and
/// durable UI ports while keeping sync execution unavailable until the real
/// AppContainer/SAF/remote service bundle is attached.
final class SyncTuneComposition {
  SyncTuneComposition._({
    required this.channel,
    required this.brokerRoot,
    required this.targets,
    required this.runner,
    required this.runtime,
    required this.rootRevoker,
    required this.database,
    required this.initializationError,
    required this.webDavSettingsPort,
    required this._webDavClient,
    required this.lifecycleListener,
    this.deletionPort,
  });

  final BrokerMethodChannel channel;
  final MutableBrokerRootPort brokerRoot;
  final CompositionTargetPort targets;
  final CompositionConfirmedSyncRunner runner;
  final ForegroundSyncRuntime runtime;
  final BrokerRootRevoker rootRevoker;
  final SyncTuneDatabase? database;
  final String? initializationError;
  final WebDavSettingsPort? webDavSettingsPort;
  final CompositionWebDavClientLifecycle? _webDavClient;
  final MusicDeletionPort? deletionPort;
  AppLifecycleListener? lifecycleListener;
  int _rootRequest = 0;
  bool _disposed = false;

  /// Applies the production port bindings without exposing Riverpod's
  /// internal Override type as part of the composition API.
  Widget provide(Widget child) {
    return ProviderScope(
      overrides: [
        musicScannerPortProvider.overrideWithValue(
          database == null
              ? BrokerMusicScanner(channel: channel)
              : CatalogEnrichingMusicScanner(
                  delegate: BrokerMusicScanner(channel: channel),
                  catalog: database!,
                  configEpoch: () => targets.configEpoch,
                ),
        ),
        syncRuntimePortProvider.overrideWithValue(runtime),
        if (database != null)
          musicFavoritesPortProvider.overrideWithValue(
            DatabaseMusicFavoritesPort(
              database: database!,
              configEpoch: () => targets.configEpoch,
            ),
          ),
        if (database != null)
          themePreferencePortProvider.overrideWithValue(
            DatabaseThemePreferencePort(database!),
          ),
        if (webDavSettingsPort != null)
          webDavSettingsPortProvider.overrideWithValue(webDavSettingsPort!),
        webDavConnectionCheckPortProvider.overrideWithValue(
          WebDavConnectionChecker(
            savedSettings: webDavSettingsPort is WebDavSettingsLoader
                ? webDavSettingsPort as WebDavSettingsLoader
                : null,
            transportChannel: channel,
          ),
        ),
        if (database != null)
          languagePreferencePortProvider.overrideWithValue(
            DatabaseLanguagePreferencePort(database!),
          ),
        if (deletionPort != null)
          musicDeletionPortProvider.overrideWithValue(deletionPort!),
      ],
      child: child,
    );
  }

  static Future<SyncTuneComposition> production({
    BrokerMethodChannel? channel,
    WebDavSettingsPort? webDavSettingsPort,
    CompositionRuntimeEvidenceGate? runtimeEvidenceGate,
    SyncNotificationPort? notificationPort,
    bool allowBackgroundExecution = true,
  }) async {
    final brokerChannel = channel ?? const FlutterBrokerMethodChannel();
    String? privatePath;
    try {
      privatePath = await brokerChannel.invokeMethod<String>(
        'privateDatabasePath',
      );
    } catch (_) {
      // The UI remains useful on a host without the native probe channel;
      // durable ports simply stay unbound and sync remains unavailable.
    }
    SyncTuneDatabase? database;
    String? initializationError;
    if (privatePath != null && privatePath.isNotEmpty) {
      SyncTuneDatabase? candidate;
      try {
        candidate = openSyncTuneDatabase(privatePath);
        // Force Drift to open the executor and run migrations now, so a
        // schema/path failure cannot be mistaken for a usable composition.
        await candidate.customSelect('SELECT 1').get();
        database = candidate;
      } catch (_) {
        await candidate?.closeStore();
        database = null;
        initializationError = 'Local data service initialization failed. Sync and favorites persistence are disabled.';
      }
    } else {
      initializationError = 'The platform did not provide a private database location. Sync and favorites persistence are disabled.';
    }

    final targets = CompositionTargetPort();
    final brokerRoot = MutableBrokerRootPort();
    final effectiveEvidenceGate =
        runtimeEvidenceGate ??
        PersistedRuntimeEvidenceGate(channel: brokerChannel, root: brokerRoot);
    WebDavSettingsPort? configuredWebDav = webDavSettingsPort;
    if (configuredWebDav == null && database != null) {
      configuredWebDav = DatabaseWebDavSettingsPort(
        database: database,
        credentials: MethodChannelBrokerCredentialStore(channel: brokerChannel),
        onNamespaceChanged: targets.setConfigEpoch,
        onCredentialEpochChanged: targets.setCredentialEpoch,
      );
      // Restore the namespace before the first root can be selected. A
      // password edit later keeps this same namespace; endpoint or username
      // changes get a new one and invalidate the runtime target.
      try {
        await (configuredWebDav as WebDavSettingsLoader).load();
      } catch (_) {
        // The settings screen still exposes the bound port; it will report a
        // save failure if the database or credential broker remains unusable.
      }
    }
    final runner = CompositionConfirmedSyncRunner();
    final webDavLoader = configuredWebDav;
    CompositionWebDavClient? configuredWebDavClient;
    if (database != null && webDavLoader is WebDavSettingsLoader) {
      try {
        final deviceId = await database.loadOrCreateDeviceId();
        final brokerScanner = BrokerMusicScanner(channel: brokerChannel);
        final brokerObjects = BrokerLocalObjectStore(
          channel: brokerChannel,
          root: brokerRoot,
        );
        SyncRoot activeRoot() {
          final target = targets.current;
          if (target == null) {
            throw const NeedsRescan('authorized root is unavailable');
          }
          return SyncRoot(
            target.rootToken,
            generation: target.rootGeneration,
            remoteNamespace: target.configEpoch,
          );
        }

        final local = CatalogRecordingLocalObjectStore(
          delegate: brokerObjects,
          catalog: database,
          activeRoot: activeRoot,
        );
        final localSnapshots = BrokerLocalSnapshotProvider(
          scanner: _BrokerSnapshotScanPort(scanner: brokerScanner),
          root: brokerRoot,
          deviceId: deviceId,
          catalog: database,
          objects: local,
        );
        final client = CompositionWebDavClient(
          settings: webDavLoader as WebDavSettingsLoader,
          credentials: MethodChannelBrokerCredentialStore(
            channel: brokerChannel,
          ),
          targets: targets,
          transportChannel: brokerChannel,
          root: brokerRoot,
        );
        configuredWebDavClient = client;
        runner.services = CompositionSyncServices(
          remoteMusicImport: (token) => client.importCloudMusic(token: token),
          localSnapshots: localSnapshots,
          remoteSnapshots: _ConfiguredRemoteSnapshotProvider(client),
          baseline: database,
          local: local,
          remote: CompositionRemoteRepository(client),
          journal: database,
          plans: database,
          capabilityCheck: _ProductionCapabilityCheck(
            channel: brokerChannel,
            root: brokerRoot,
            client: client,
            evidenceGate: effectiveEvidenceGate,
          ).call,
        );
      } catch (_) {
        initializationError ??=
            'Sync service initialization failed. Sync remains disabled.';
      }
    }
    final effectiveNotificationPort = notificationPort ??
        PlatformSyncNotificationPort(
          channel: brokerChannel,
          isAndroid: Platform.isAndroid,
        );
    final runtime = ForegroundSyncRuntime(
      targetPort: targets,
      runner: runner,
      notificationPort: effectiveNotificationPort,
      allowBackgroundExecution: allowBackgroundExecution,
    );
    MusicDeletionPort? deletionPort;
    if (database != null && runner.services != null) {
      deletionPort = SyncTuneMusicDeletionService(
        database: database,
        local: runner.services!.local,
        targets: targets,
        runtime: runtime,
      );
      unawaited(deletionPort.recoverTasks());
    }
    final composition = SyncTuneComposition._(
      channel: brokerChannel,
      brokerRoot: brokerRoot,
      targets: targets,
      runner: runner,
      runtime: runtime,
      rootRevoker: BrokerRootRevoker(channel: brokerChannel),
      database: database,
      initializationError: initializationError,
      webDavSettingsPort: configuredWebDav,
      webDavClient: configuredWebDavClient,
      deletionPort: deletionPort,
      lifecycleListener: null,
    );
    // Composition tests and non-widget hosts may construct the bundle before
    // a WidgetsBinding exists. The app entrypoint initializes it first, so the
    // listener is present in production while the port remains usable in
    // those hosts.
    try {
      composition.lifecycleListener = AppLifecycleListener(
        onStateChange: composition._onAppLifecycleState,
      );
    } catch (_) {
      composition.lifecycleListener = null;
    }
    runtime.start();
    if (Platform.isAndroid) {
      unawaited(effectiveNotificationPort.requestPermission());
    }
    return composition;
  }

  Future<RootGrant?> pickRoot() async {
    if (_disposed) return null;
    final request = ++_rootRequest;
    final before = brokerRoot.current;
    final result = await channel.invokeMethod<Map<Object?, Object?>>(
      'pickRoot',
    );
    // Picker cancellation leaves the existing native grant active.
    if (!_isCurrentRootRequest(request) ||
        !_sameBrokerRoot(before, brokerRoot.current) ||
        result == null ||
        result['status'] != 'ok') {
      return null;
    }
    final grant = _grantFromResponse(result);
    _setGrant(grant);
    return grant;
  }

  Future<RootGrant?> restoreRoot() async {
    if (_disposed) return null;
    final request = ++_rootRequest;
    final before = brokerRoot.current;
    try {
      final result = await channel.invokeMethod<Map<Object?, Object?>>(
        'restoreRoot',
      );
      if (!_isCurrentRootRequest(request) ||
          !_sameBrokerRoot(before, brokerRoot.current)) {
        return null;
      }
      if (result == null || result['status'] != 'ok') {
        _setGrant(null);
        return null;
      }
      final grant = _grantFromResponse(result);
      _setGrant(grant);
      return grant;
    } catch (_) {
      if (_isCurrentRootRequest(request) &&
          _sameBrokerRoot(before, brokerRoot.current)) {
        _setGrant(null);
      }
      return null;
    }
  }

  Future<bool> revokeRoot(RootGrant grant) async {
    if (_disposed) return false;
    final request = ++_rootRequest;
    final before = brokerRoot.current;
    final revoked = await rootRevoker.revoke(grant);
    // A later picker/restore owns the current broker generation. Treat this
    // completion as stale so an old revoke cannot clear or report failure for
    // the newly selected root.
    if (!_isCurrentRootRequest(request) ||
        !_sameBrokerGrant(before, grant) ||
        !_sameBrokerRoot(before, brokerRoot.current)) {
      return true;
    }
    if (revoked) {
      _setGrant(null);
    } else {
      // Native revoke may have cleared its active generation before reporting
      // a provider error. Stop all Dart work and leave the UI grant visible so
      // Settings can show that authorization is uncertain.
      await runtime.cancel();
      brokerRoot.current = null;
      targets.setRoot(null);
    }
    return revoked;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_rootRequest;
    lifecycleListener?.dispose();
    await runtime.disposeAndWait();
    await _webDavClient?.dispose();
    await targets.close();
    await database?.closeStore();
  }

  void _setGrant(RootGrant? grant) {
    brokerRoot.current = grant == null
        ? null
        : BrokerRoot(token: grant.token, generation: grant.generation);
    targets.setRoot(grant);
  }

  bool _isCurrentRootRequest(int request) =>
      !_disposed && request == _rootRequest;

  bool _sameBrokerRoot(BrokerRoot? left, BrokerRoot? right) =>
      left?.token == right?.token && left?.generation == right?.generation;

  bool _sameBrokerGrant(BrokerRoot? root, RootGrant grant) =>
      root?.token == grant.token && root?.generation == grant.generation;

  void _onAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        runtime.onResume();
        break;
      case AppLifecycleState.inactive:
        // Focus loss while the window remains visible does not cancel work.
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        runtime.onPause();
        break;
    }
  }

  RootGrant? _grantFromResponse(Map<Object?, Object?>? result) {
    if (result == null || result['status'] != 'ok') return null;
    final path = result['path']?.toString() ?? '';
    final token = result['token']?.toString() ?? '';
    final generation = result['generation']?.toString() ?? '';
    if (path.isEmpty || token.isEmpty || generation.isEmpty) {
      throw StateError(
        'The system picker did not return a valid authorized root folder',
      );
    }
    return RootGrant(path: path, token: token, generation: generation);
  }
}
