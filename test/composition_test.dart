import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:synctune/app/music/music_scan.dart';
import 'package:synctune/app/music/music_scan_port.dart';
import 'package:synctune/app/settings/settings_view_model.dart';
import 'package:synctune/app/sync/sync_gate.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';
import 'package:synctune/data/sync_tune_database.dart';
import 'package:synctune/infrastructure/composition/synctune_composition.dart';
import 'package:synctune/infrastructure/platform/broker_credentials.dart';
import 'package:synctune/infrastructure/runtime/foreground_sync_runtime.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

void main() {
  test(
    'catalog enrichment gives UI and core the same stable entry id',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final scanner = CatalogEnrichingMusicScanner(
        delegate: _Scanner(<Object?, Object?>{
          'status': 'ok',
          'generation': 'generation-1',
          'complete': true,
          'items': <Object?>[
            <Object?, Object?>{
              'relativePath': 'album/song.mp3',
              'size': 3,
              'extension': 'mp3',
            },
          ],
        }),
        catalog: database,
        configEpoch: () => 'default',
      );
      const grant = RootGrant(
        path: 'music',
        token: 'root-token',
        generation: 'generation-1',
      );

      final response = await scanner.scan(grant);
      final item = (response['items'] as List).single as Map<Object?, Object?>;
      final id = item['id'] as String;
      expect(
        id,
        await database.ensureCatalogEntryId(
          const SyncRoot(
            'root-token',
            generation: 'generation-1',
            remoteNamespace: 'default',
          ),
          SyncPath.parse('album/song.mp3'),
        ),
      );
    },
  );

  test('database favorite adapter uses persisted device and Lamport state', () async {
    final database = SyncTuneDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final favorites = DatabaseMusicFavoritesPort(
      database: database,
      configEpoch: () => 'default',
    );
    const grant = RootGrant(
      path: 'music',
      token: 'root-token',
      generation: 'generation-1',
    );
    const track = MusicTrack(
      id: 'catalog-stable-id',
      relativePath: 'song.mp3',
      size: 3,
      extension: 'mp3',
    );

    await database.customInsert(
      'INSERT INTO local_catalog(root_id, generation, relative_path, entry_id) '
      'VALUES (?, ?, ?, ?)',
      variables: [
        Variable.withString('root-token|default'),
        Variable.withString('generation-1'),
        Variable.withString('song.mp3'),
        Variable.withString('catalog-stable-id'),
      ],
    );
    await favorites.setFavorite(grant: grant, track: track, value: true);
    expect(await favorites.loadFavorites(grant), contains('catalog-stable-id'));
    expect(await database.nextLamport(), 2);
  });

  test(
    'theme preference adapter persists system/light/dark selection',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final preferences = DatabaseThemePreferencePort(database);

      expect(await preferences.load(), ThemeMode.system);
      await preferences.save(ThemeMode.dark);
      expect(await preferences.load(), ThemeMode.dark);
    },
  );

  test('the composition gate is closed by default but supports explicit test injection', () async {
    const target = SyncRuntimeTarget(
      rootToken: 'root',
      rootGeneration: 'generation',
      configEpoch: 'configuration',
    );
    final runner = CompositionConfirmedSyncRunner();
    expect((await runner.check(target)).status, SyncGateStatus.unavailable);

    final database = SyncTuneDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final services = CompositionSyncServices(
      localSnapshots: _UnusedLocalSnapshots(),
      remoteSnapshots: _UnusedRemoteSnapshots(),
      baseline: database,
      local: _UnusedLocalObjects(),
      remote: _UnusedRemoteRepository(),
      journal: database,
      plans: database,
    );
    runner.services = services;
    expect((await runner.check(target)).status, SyncGateStatus.unavailable);

    runner.services = CompositionSyncServices(
      localSnapshots: services.localSnapshots,
      remoteSnapshots: services.remoteSnapshots,
      baseline: services.baseline,
      local: services.local,
      remote: services.remote,
      journal: services.journal,
      plans: services.plans,
      capabilityCheck: (_, {required token}) async => const SyncGateState(
        status: SyncGateStatus.ready,
        title: '测试闸门已通过',
        message: '显式注入的测试能力检查',
      ),
    );
    expect((await runner.check(target)).status, SyncGateStatus.ready);
  });

  test(
    'WebDAV settings restore through DB and protected credentials',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final credentials = _Credentials();
      final namespaces = <String>[];
      final credentialEpochs = <String>[];
      final settings = DatabaseWebDavSettingsPort(
        database: database,
        credentials: credentials,
        onNamespaceChanged: namespaces.add,
        onCredentialEpochChanged: credentialEpochs.add,
      );

      const saved = WebDavSettings(
        endpoint: 'https://dav.example/music/',
        username: 'CaseSensitiveUser',
        password: 'secret-value',
      );
      await settings.save(saved);
      final persisted = await database.loadSetting('webdav.connection');
      expect(persisted, contains(saved.endpoint));
      expect(persisted, contains(saved.username));
      expect(persisted, isNot(contains(saved.password)));
      expect(await database.loadSetting('webdav.password'), isNull);
      expect(namespaces, hasLength(1));
      expect(credentialEpochs, hasLength(1));

      final restored = await settings.load();
      expect(restored.endpoint, saved.endpoint);
      expect(restored.username, saved.username);
      expect(restored.password, saved.password);
      expect(namespaces, hasLength(2));
      expect(namespaces[0], namespaces[1]);
      expect(credentialEpochs, hasLength(2));
      expect(credentialEpochs[0], credentialEpochs[1]);

      await settings.save(
        const WebDavSettings(
          endpoint: 'https://dav.example/music/',
          username: 'CaseSensitiveUser',
          password: 'new-secret',
        ),
      );
      expect(namespaces, hasLength(3));
      expect(namespaces[1], namespaces[2]);
      expect(credentialEpochs[1], isNot(credentialEpochs[2]));

      await settings.save(
        const WebDavSettings(
          endpoint: 'https://dav.example/music/',
          username: 'different-user',
          password: 'new-secret',
        ),
      );
      expect(namespaces.last, isNot(namespaces[1]));

      await settings.save(
        const WebDavSettings(
          endpoint: 'https://dav.example/music/',
          username: 'different-user',
          clearPassword: true,
        ),
      );
      final cleared = await settings.load();
      expect(cleared.password, isEmpty);
      expect(
        DatabaseWebDavSettingsPort.namespaceFor(
          'https://dav.example/music',
          'different-user',
        ),
        DatabaseWebDavSettingsPort.namespaceFor(
          'https://dav.example/music/',
          'different-user',
        ),
      );
    },
  );

  test(
    'WebDAV saves are serialized before the next connection can commit',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final credentials = _BlockingCredentials();
      final settings = DatabaseWebDavSettingsPort(
        database: database,
        credentials: credentials,
        onNamespaceChanged: (_) {},
      );

      final first = settings.save(
        const WebDavSettings(
          endpoint: 'https://one.example/music',
          username: 'first',
          password: 'first-secret',
        ),
      );
      await credentials.firstSaveStarted.future;
      final second = settings.save(
        const WebDavSettings(
          endpoint: 'https://two.example/music',
          username: 'second',
          password: 'second-secret',
        ),
      );
      expect(await database.loadSetting('webdav.connection'), isNull);
      credentials.releaseFirst.complete();
      await Future.wait([first, second]);
      final restored = await settings.load();
      expect(restored.endpoint, 'https://two.example/music/');
      expect(restored.username, 'second');
      expect(restored.password, 'second-secret');
    },
  );

  test(
    'a slow load cannot publish an older namespace after a newer save',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final credentials = _SlowReadCredentials();
      final namespaces = <String>[];
      final settings = DatabaseWebDavSettingsPort(
        database: database,
        credentials: credentials,
        onNamespaceChanged: namespaces.add,
      );
      await settings.save(
        const WebDavSettings(
          endpoint: 'https://one.example/music/',
          username: 'one',
          password: 'first-secret',
        ),
      );

      credentials.blockNextRead();
      final loading = settings.load();
      await credentials.readStarted.future;
      final saving = settings.save(
        const WebDavSettings(
          endpoint: 'https://two.example/music/',
          username: 'two',
          password: 'second-secret',
        ),
      );
      credentials.readRelease.complete();
      await Future.wait([loading, saving]);

      expect(
        namespaces.last,
        DatabaseWebDavSettingsPort.namespaceFor(
          'https://two.example/music/',
          'two',
        ),
      );
    },
  );

  test('an explicit password clear does not resurrect a legacy secret after cleanup failure', () async {
    final database = SyncTuneDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final credentials = _CleanupFailingCredentials();
    const endpoint = 'https://one.example/music/';
    const username = 'legacy-user';
    final oldAccount = DatabaseWebDavSettingsPort.credentialAccountFor(
      endpoint,
      username,
    );
    credentials.values[oldAccount] = 'legacy-secret';
    await database.saveSetting(
      'webdav.connection',
      jsonEncode(<String, String>{
        'endpoint': endpoint,
        'username': username,
        'credentialEpoch': 'old',
        'credentialAccount': oldAccount,
      }),
    );
    final cleanupMessages = <String>[];
    final settings = DatabaseWebDavSettingsPort(
      database: database,
      credentials: credentials,
      onNamespaceChanged: (_) {},
      onCredentialCleanupFailed: cleanupMessages.add,
    );

    await settings.save(
      const WebDavSettings(
        endpoint: endpoint,
        username: username,
        clearPassword: true,
      ),
    );

    expect((await settings.load()).password, isEmpty);
    expect(cleanupMessages, hasLength(1));
    expect(settings.takeWarning(), contains('清理失败'));
  });

  test('a cleared credential fails closed in the configured client', () async {
    final targets = CompositionTargetPort(configEpoch: 'namespace-a');
    addTearDown(targets.close);
    targets.setRoot(
      const RootGrant(
        path: 'music',
        token: 'root-token',
        generation: 'generation-1',
      ),
    );
    final credentials = _Credentials();
    final oldAccount = DatabaseWebDavSettingsPort.credentialAccountFor(
      'https://one.example/music/',
      'legacy-user',
    );
    credentials
            .values['${DatabaseWebDavSettingsPort.credentialService}|$oldAccount'] =
        'legacy-secret';
    final client = CompositionWebDavClient(
      settings: _StaticWebDavSettingsLoader(
        const WebDavSettings(
          endpoint: 'https://one.example/music/',
          username: 'legacy-user',
          credentialAccount: '',
          credentialAccountPresent: true,
        ),
      ),
      credentials: credentials,
      targets: targets,
    );
    addTearDown(client.dispose);

    await expectLater(
      client.ensureCredentials(token: const NeverCancelled()),
      throwsA(isA<SyncRuntimeNotReady>()),
    );
    expect(credentials.reads, isEmpty);
  });

  test('legacy WebDAV records still restore their stable credential account', () async {
    final targets = CompositionTargetPort(configEpoch: 'namespace-a');
    addTearDown(targets.close);
    targets.setRoot(
      const RootGrant(
        path: 'music',
        token: 'root-token',
        generation: 'generation-1',
      ),
    );
    final credentials = _Credentials();
    final account = DatabaseWebDavSettingsPort.credentialAccountFor(
      'https://one.example/music/',
      'legacy-user',
    );
    credentials
            .values['${DatabaseWebDavSettingsPort.credentialService}|$account'] =
        'legacy-secret';
    final client = CompositionWebDavClient(
      settings: _StaticWebDavSettingsLoader(
        const WebDavSettings(
          endpoint: 'https://one.example/music/',
          username: 'legacy-user',
        ),
      ),
      credentials: credentials,
      targets: targets,
    );
    addTearDown(client.dispose);

    await client.ensureCredentials(token: const NeverCancelled());
    expect(credentials.reads, contains(account));
  });

  test(
    'a queued failed save cannot hide an earlier committed identity',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final namespaces = <String>[];
      final credentialEpochs = <String>[];
      final settings = DatabaseWebDavSettingsPort(
        database: database,
        credentials: _Credentials(),
        onNamespaceChanged: namespaces.add,
        onCredentialEpochChanged: credentialEpochs.add,
      );

      final first = settings.save(
        const WebDavSettings(
          endpoint: 'https://one.example/music/',
          username: 'one',
          password: 'first-secret',
        ),
      );
      final second = settings.save(
        const WebDavSettings(
          endpoint: 'http://invalid.example/music/',
          username: 'two',
          password: 'second-secret',
        ),
      );
      await first;
      await expectLater(second, throwsA(isA<FormatException>()));

      expect(namespaces, [
        DatabaseWebDavSettingsPort.namespaceFor(
          'https://one.example/music/',
          'one',
        ),
      ]);
      expect(credentialEpochs, hasLength(1));
      final restored = await settings.load();
      expect(restored.endpoint, 'https://one.example/music/');
      expect(restored.username, 'one');
    },
  );

  test('a committed save updates the target before old credential cleanup finishes', () async {
    final database = SyncTuneDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    const oldEndpoint = 'https://one.example/music/';
    const oldUsername = 'one';
    final oldAccount = DatabaseWebDavSettingsPort.credentialAccountFor(
      oldEndpoint,
      oldUsername,
    );
    final credentials = _BlockingDeleteCredentials();
    credentials
            .values['${DatabaseWebDavSettingsPort.credentialService}|$oldAccount'] =
        'old-secret';
    await database.saveSetting(
      'webdav.connection',
      jsonEncode(<String, String>{
        'endpoint': oldEndpoint,
        'username': oldUsername,
        'credentialEpoch': 'old-epoch',
        'credentialAccount': oldAccount,
      }),
    );
    final targets = CompositionTargetPort(
      configEpoch: DatabaseWebDavSettingsPort.namespaceFor(
        oldEndpoint,
        oldUsername,
      ),
    );
    addTearDown(targets.close);
    targets.setRoot(
      const RootGrant(
        path: 'music',
        token: 'root-token',
        generation: 'generation-1',
      ),
    );
    final oldIdentity = targets.current!.identity;
    final settings = DatabaseWebDavSettingsPort(
      database: database,
      credentials: credentials,
      onNamespaceChanged: targets.setConfigEpoch,
      onCredentialEpochChanged: targets.setCredentialEpoch,
    );

    final saving = settings.save(
      const WebDavSettings(
        endpoint: 'https://two.example/music/',
        username: 'two',
        password: 'new-secret',
      ),
    );
    await credentials.deleteStarted.future;

    expect(targets.current!.identity, isNot(oldIdentity));
    expect(
      targets.current!.configEpoch,
      DatabaseWebDavSettingsPort.namespaceFor(
        'https://two.example/music/',
        'two',
      ),
    );
    credentials.releaseDelete.complete();
    await saving;
  });

  test(
    'callback failures do not turn a committed settings save into a failure',
    () async {
      final database = SyncTuneDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final settings = DatabaseWebDavSettingsPort(
        database: database,
        credentials: _Credentials(),
        onNamespaceChanged: (_) =>
            throw StateError('namespace callback failure'),
        onCredentialEpochChanged: (_) =>
            throw StateError('epoch callback failure'),
      );

      await settings.save(
        const WebDavSettings(
          endpoint: 'https://one.example/music/',
          username: 'one',
          password: 'secret',
        ),
      );

      expect(
        await database.loadSetting('webdav.connection'),
        contains('one.example'),
      );
      expect(settings.takeWarning(), contains('设置已保存'));
    },
  );

  test('the composition repository forwards remote plan recovery', () async {
    final targets = CompositionTargetPort(configEpoch: 'namespace-a');
    addTearDown(targets.close);
    targets.setRoot(
      const RootGrant(
        path: 'music',
        token: 'root-token',
        generation: 'generation-1',
      ),
    );
    final client = CompositionWebDavClient(
      settings: _StaticWebDavSettingsLoader(
        const WebDavSettings(
          endpoint: 'https://one.example/music/',
          username: 'user',
          password: 'secret',
        ),
      ),
      credentials: _Credentials(),
      targets: targets,
    );
    addTearDown(client.dispose);
    final repository = CompositionRemoteRepository(client);
    expect(repository, isA<RemotePlanRecovery>());

    final recovered = await repository.recoverPendingPlan(
      const SyncRoot(
        'root-token',
        generation: 'generation-1',
        remoteNamespace: 'namespace-a',
      ),
      const SyncPlan(
        planId: 'plan-1',
        generation: 'generation-1',
        operations: <SyncOperation>[],
        deletionsSuppressed: false,
        remoteNamespace: 'namespace-a',
      ),
      journal: const <JournalRecord>[],
    );
    expect(recovered, isEmpty);
  });

  for (final change in <String>['root', 'namespace', 'credential']) {
    test('remote recovery rejects a target changed during the request ($change)', () async {
      final targets = CompositionTargetPort(configEpoch: 'namespace-a');
      addTearDown(targets.close);
      targets.setRoot(
        const RootGrant(
          path: 'music',
          token: 'root-token',
          generation: 'generation-1',
        ),
      );
      final adapter = _DelayedHeadAdapter();
      final client = CompositionWebDavClient(
        settings: _StaticWebDavSettingsLoader(
          const WebDavSettings(
            endpoint: 'https://one.example/music/',
            username: 'user',
            password: 'secret',
          ),
        ),
        credentials: _Credentials(),
        targets: targets,
        dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
      );
      addTearDown(client.dispose);
      final repository = CompositionRemoteRepository(client);
      final path = SyncPath.parse('song.mp3');
      final source = SyncEntry.file(
        id: 'stable-id',
        path: path,
        size: 3,
        sha256:
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        modifiedAtUtc: DateTime.utc(2026, 10, 7),
      );
      final plan = SyncPlan(
        planId: 'plan-1',
        generation: 'generation-1',
        operations: <SyncOperation>[
          SyncOperation(
            id: 'operation-1',
            kind: SyncOperationKind.putLocalToRemote,
            path: path,
            planId: 'plan-1',
            generation: 'generation-1',
            source: source,
            condition: const CreateOnly(),
            metadataCondition: const CreateOnly(),
          ),
        ],
        deletionsSuppressed: false,
        remoteNamespace: 'namespace-a',
      );
      final recovery = repository.recoverPendingPlan(
        const SyncRoot(
          'root-token',
          generation: 'generation-1',
          remoteNamespace: 'namespace-a',
        ),
        plan,
        journal: <JournalRecord>[
          JournalRecord(
            planId: 'plan-1',
            generation: 'generation-1',
            operationId: 'operation-1',
            path: path,
            state: JournalState.staged,
            atUtc: DateTime.utc(2026, 10, 7),
            stagingKey: 'stage-1',
            sha256: source.sha256,
            length: source.size,
            condition: const CreateOnly().fingerprint,
            metadataCondition: const CreateOnly().fingerprint,
          ),
        ],
      );
      await adapter.started.future;
      switch (change) {
        case 'root':
          targets.setRoot(
            const RootGrant(
              path: 'other',
              token: 'other-root',
              generation: 'generation-2',
            ),
          );
        case 'namespace':
          targets.setConfigEpoch('namespace-b');
        case 'credential':
          targets.setCredentialEpoch('credential-new');
      }
      adapter.release.complete();

      await expectLater(
        recovery,
        throwsA(anyOf(isA<SyncCancelled>(), isA<NeedsRescan>())),
      );
    });
  }
}

final class _Scanner implements MusicScannerPort {
  _Scanner(this.value);

  final Map<Object?, Object?> value;

  @override
  Future<Map<Object?, Object?>> scan(RootGrant grant) async => value;
}

final class _Credentials implements BrokerCredentialStore {
  final values = <String, String>{};
  final reads = <String>[];

  String _key(String service, String account) => '$service|$account';

  @override
  Future<void> save({
    required String service,
    required String account,
    required String secret,
  }) async {
    values[_key(service, account)] = secret;
  }

  @override
  Future<String?> read({
    required String service,
    required String account,
  }) async {
    reads.add(account);
    return values[_key(service, account)];
  }

  @override
  Future<void> delete({
    required String service,
    required String account,
  }) async {
    values.remove(_key(service, account));
  }
}

final class _StaticWebDavSettingsLoader implements WebDavSettingsLoader {
  const _StaticWebDavSettingsLoader(this.settings);

  final WebDavSettings settings;

  @override
  Future<WebDavSettings> load() async => settings;
}

final class _BlockingDeleteCredentials implements BrokerCredentialStore {
  final values = <String, String>{};
  final deleteStarted = Completer<void>();
  final releaseDelete = Completer<void>();

  String _key(String service, String account) => '$service|$account';

  @override
  Future<void> save({
    required String service,
    required String account,
    required String secret,
  }) async {
    values[_key(service, account)] = secret;
  }

  @override
  Future<String?> read({
    required String service,
    required String account,
  }) async => values[_key(service, account)];

  @override
  Future<void> delete({
    required String service,
    required String account,
  }) async {
    if (!deleteStarted.isCompleted) deleteStarted.complete();
    await releaseDelete.future;
    values.remove(_key(service, account));
  }
}

final class _DelayedHeadAdapter implements HttpClientAdapter {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'HEAD') {
      started.complete();
      await release.future;
      return ResponseBody.fromString('', 404);
    }
    return ResponseBody.fromString('', 404);
  }

  @override
  void close({bool force = false}) {}
}

final class _BlockingCredentials implements BrokerCredentialStore {
  final firstSaveStarted = Completer<void>();
  final releaseFirst = Completer<void>();
  final values = <String, String>{};
  int _saveCount = 0;

  String _key(String service, String account) => '$service|$account';

  @override
  Future<void> save({
    required String service,
    required String account,
    required String secret,
  }) async {
    _saveCount++;
    if (_saveCount == 1) {
      firstSaveStarted.complete();
      await releaseFirst.future;
    }
    values[_key(service, account)] = secret;
  }

  @override
  Future<String?> read({
    required String service,
    required String account,
  }) async => values[_key(service, account)];

  @override
  Future<void> delete({
    required String service,
    required String account,
  }) async {
    values.remove(_key(service, account));
  }
}

final class _SlowReadCredentials implements BrokerCredentialStore {
  final values = <String, String>{};
  final readStarted = Completer<void>();
  final readRelease = Completer<void>();
  bool _blockRead = false;

  String _key(String service, String account) => '$service|$account';

  void blockNextRead() => _blockRead = true;

  @override
  Future<void> save({
    required String service,
    required String account,
    required String secret,
  }) async {
    values[_key(service, account)] = secret;
  }

  @override
  Future<String?> read({
    required String service,
    required String account,
  }) async {
    final value = values[_key(service, account)];
    if (_blockRead) {
      _blockRead = false;
      readStarted.complete();
      await readRelease.future;
    }
    return value;
  }

  @override
  Future<void> delete({
    required String service,
    required String account,
  }) async {
    values.remove(_key(service, account));
  }
}

final class _CleanupFailingCredentials implements BrokerCredentialStore {
  final values = <String, String>{};

  @override
  Future<void> save({
    required String service,
    required String account,
    required String secret,
  }) async {
    values[account] = secret;
  }

  @override
  Future<String?> read({
    required String service,
    required String account,
  }) async => values[account];

  @override
  Future<void> delete({
    required String service,
    required String account,
  }) async {
    throw StateError('injected cleanup failure');
  }
}

final class _UnusedLocalSnapshots implements LocalSnapshotProvider {
  @override
  Future<SyncSnapshot> capture(
    SyncRoot root, {
    CancellationToken token = const NeverCancelled(),
  }) => Future<SyncSnapshot>.error(StateError('not used by gate test'));
}

final class _UnusedRemoteSnapshots implements RemoteSnapshotProvider {
  @override
  Future<RemoteSnapshot> capture(
    SyncRoot root, {
    CancellationToken token = const NeverCancelled(),
  }) => Future<RemoteSnapshot>.error(StateError('not used by gate test'));
}

final class _UnusedLocalObjects implements LocalObjectStore {
  Future<T> _unused<T>() =>
      Future<T>.error(StateError('not used by gate test'));

  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) => _unused();

  @override
  Future<StagedObject> stage(
    SyncPath path,
    Stream<List<int>> content, {
    required String expectedSha256,
    CancellationToken token = const NeverCancelled(),
  }) => _unused();

  @override
  Future<Stream<List<int>>> openStaged(
    StagedObject staged, {
    CancellationToken token = const NeverCancelled(),
  }) => _unused();

  @override
  Future<bool> verifyStaged(
    StagedObject staged, {
    required String expectedSha256,
    required int expectedLength,
    CancellationToken token = const NeverCancelled(),
  }) => _unused();

  @override
  Future<void> commitStaged(
    SyncPath path,
    StagedObject staged, {
    required SyncEntry entry,
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) => _unused();

  @override
  Future<void> delete(
    SyncPath path, {
    required LocalCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) => _unused();

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    CancellationToken token = const NeverCancelled(),
  }) => _unused();
}

final class _UnusedRemoteRepository implements RemoteRepository {
  Future<T> _unused<T>() =>
      Future<T>.error(StateError('not used by gate test'));

  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) => _unused();

  @override
  Future<String> put(
    SyncPath path,
    Stream<List<int>> content, {
    required SyncEntry entry,
    required RemoteCondition condition,
    required RemoteCondition metadataCondition,
    CancellationToken token = const NeverCancelled(),
  }) => _unused();

  @override
  Future<void> delete(
    SyncPath path, {
    required MatchEtag condition,
    SyncEntry? tombstone,
    RemoteCondition? metadataCondition,
    CancellationToken token = const NeverCancelled(),
  }) => _unused();

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    required RemoteCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) => _unused();
}
