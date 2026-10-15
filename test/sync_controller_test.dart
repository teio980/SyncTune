import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/sync/local_store.dart';
import 'package:synctune/sync/state_store.dart';
import 'package:synctune/sync/sync_controller.dart';
import 'package:synctune/sync/sync_engine.dart';
import 'package:synctune/sync/sync_model.dart';
import 'package:synctune/sync/sync_platform.dart';
import 'package:synctune/sync/webdav_client.dart';

void main() {
  late Directory directory;
  late SqliteStateStore state;
  late SyncSettings settings;
  late _Credentials credentials;
  late _Host host;
  late _StalledAdapter adapter;
  late SyncController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('synctune-reset-');
    state = SqliteStateStore('${directory.path}/state.sqlite');
    await state.open();
    settings = SyncSettings(
      localRoot: '${directory.path}/music',
      localRootId: 'reset-test',
      localGeneration: 'v2',
      serverUrl: 'https://example.test/dav',
      remoteRoot: '',
      username: 'listener',
      language: 'en',
    );
    await Directory(settings.localRoot).create();
    state.ensureIdentity(settings.syncIdentity);
    state.saveSettings({
      'server_url': settings.serverUrl,
    }, identityChanged: false);
    state
        .scanCheckpoint(reuse: false)
        .recordLocal(
          SyncPath.parse('song.mp3'),
          sha256: hashBytes([1, 2, 3]),
          size: 3,
          modifiedMs: 1,
        );
    credentials = _Credentials();
    host = _Host();
    adapter = _StalledAdapter();
    controller = SyncController(
      engine: SyncEngine(
        localStore: FileLocalStore(settings.localRoot),
        webDav: WebDavClient(dio: Dio()..httpClientAdapter = adapter),
        stateStore: state,
      ),
      credentials: credentials,
      executionHost: host,
    );
  });

  tearDown(() async {
    await controller.cancelAndWait();
    controller.dispose();
    state.close();
    await directory.delete(recursive: true);
  });

  test('force reset interrupts a stalled credential read', () async {
    credentials.pending = Completer<String>();
    final running = controller.start(settings);
    expect(controller.progress.phase, SyncPhase.preparing);
    await controller.forceStopAndReset().timeout(const Duration(seconds: 2));
    await running;
    expect(controller.isRunning, isFalse);
    expect(controller.freshStartReady, isTrue);
    expect(controller.progress.phase, SyncPhase.idle);
    expect(state.scanCheckpointCount(), 0);
    expect(state.loadSettings()['server_url'], settings.serverUrl);
    credentials.pending!.complete('late secret');
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, isEmpty);
    expect(host.starts, 0);
  });

  test(
    'force reset cancels blocked network I/O and next sync starts fresh',
    () async {
      final running = controller.start(settings);
      await adapter.entered.future;
      expect(controller.isRunning, isTrue);
      await controller.forceStopAndReset().timeout(const Duration(seconds: 2));
      await running;
      expect(adapter.cancelled, isTrue);
      expect(controller.isRunning, isFalse);
      expect(controller.freshStartReady, isTrue);
      expect(state.scanCheckpointCount(), 0);
      adapter.stall = false;
      await controller.start(settings);
      expect(controller.progress.phase, SyncPhase.complete);
      expect(controller.freshStartReady, isFalse);
    },
  );

  test('reset holds the operation lock until the old host finishes', () async {
    host.pendingFinish = Completer<void>();
    final running = controller.start(settings);
    await adapter.entered.future;
    final resetting = controller.forceStopAndReset();
    await host.finishing.future;
    expect(controller.isResetting, isTrue);
    expect(controller.progress.phase, SyncPhase.stopping);
    expect(controller.beginExclusiveOperation(), isFalse);
    await expectLater(controller.start(settings), throwsA(isA<SyncFailure>()));
    expect(state.scanCheckpointCount(), greaterThan(0));
    await controller.forceStopAndReset();
    expect(controller.isResetting, isTrue);
    host.pendingFinish!.complete();
    await resetting;
    await running;
    expect(controller.configurationWriteInProgress, isFalse);
    expect(state.scanCheckpointCount(), 0);
    expect(controller.freshStartReady, isTrue);
  });
}

final class _Credentials implements SyncCredentialStore {
  Completer<String>? pending;
  @override
  Future<String> read(SyncSettings settings) async =>
      pending == null ? 'secret' : await pending!.future;
  @override
  Future<void> write(SyncSettings settings, String secret) async {}
  @override
  Future<void> delete(SyncSettings settings) async {}
}

final class _Host implements SyncExecutionHost {
  int starts = 0;
  final finishing = Completer<void>();
  Completer<void>? pendingFinish;
  @override
  Future<void> start(SyncSettings settings) async {
    starts++;
  }

  @override
  Future<void> update(SyncProgress progress) async {}
  @override
  Future<void> finish(SyncProgress progress) async {
    if (!finishing.isCompleted) finishing.complete();
    await pendingFinish?.future;
  }
}

final class _StalledAdapter implements HttpClientAdapter {
  final entered = Completer<void>();
  final requests = <RequestOptions>[];
  bool cancelled = false;
  bool stall = true;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!entered.isCompleted) entered.complete();
    if (stall) {
      await cancelFuture;
      cancelled = true;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    }
    return ResponseBody.fromString(
      '<d:multistatus xmlns:d="DAV:"><d:response>'
      '<d:href>${options.uri.path}</d:href><d:propstat><d:prop>'
      '<d:resourcetype><d:collection/></d:resourcetype></d:prop>'
      '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
      '</d:response></d:multistatus>',
      HttpStatus.multiStatus,
    );
  }

  @override
  void close({bool force = false}) {}
}
