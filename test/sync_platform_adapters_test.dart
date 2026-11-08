import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/platform/sync_platform_adapters.dart';
import 'package:synctune/sync/local_store.dart';
import 'package:synctune/sync/state_store.dart';
import 'package:synctune/sync/sync_controller.dart';
import 'package:synctune/sync/sync_engine.dart';
import 'package:synctune/sync/sync_model.dart';
import 'package:synctune/sync/sync_platform.dart';
import 'package:synctune/sync/webdav_client.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('synctune/sync_platform');
  late SyncPlatformAdapters platform;
  late Directory directory;
  late SyncSettings settings;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) respond;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('synctune-platform-');
    final music = await Directory('${directory.path}/中文 音乐').create();
    settings = SyncSettings(
      localRoot: music.path,
      localRootId: music.path,
      localGeneration: 'macos-folder-v2',
      serverUrl: 'https://example.test/dav',
      remoteRoot: '',
      username: 'listener',
      language: 'zh',
    );
    platform = SyncPlatformAdapters(channel: channel);
    calls = <MethodCall>[];
    respond = (_) async => null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return respond(call);
    });
  });

  tearDown(() async {
    channel.setMethodCallHandler(null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'folder cancellation and Unicode paths retain the native identity',
    () async {
      expect(await platform.pick(), isNull);
      respond = (_) async => <String, Object?>{
        'locator': settings.localRoot,
        'stableId': settings.localRootId,
        'generation': settings.localGeneration,
      };
      final selected = (await platform.pick())!;
      expect(selected.locator, settings.localRoot);
      expect(selected.stableId, settings.localRootId);
      expect(selected.generation, 'macos-folder-v2');
      respond = (_) async => <String, Object?>{'locator': ''};
      await expectLater(platform.pick(), throwsA(isA<SyncFailure>()));
    },
  );

  test(
    'missing credentials and secure-store calls preserve the existing key',
    () async {
      await expectLater(platform.read(settings), throwsA(isA<SyncFailure>()));
      expect(await platform.hasSavedCredential(settings), isFalse);
      await expectLater(
        platform.write(settings, ''),
        throwsA(isA<SyncFailure>()),
      );
      respond = (call) async => switch (call.method) {
        'credentialRead' => '密码 with spaces',
        'credentialExists' => true,
        _ => null,
      };
      await platform.write(settings, '密码 with spaces');
      expect(await platform.read(settings), '密码 with spaces');
      expect(await platform.hasSavedCredential(settings), isTrue);
      await platform.delete(settings);
      final identity = sha256
          .convert(utf8.encode(settings.syncIdentity))
          .toString();
      for (final call in calls) {
        expect((call.arguments as Map)['identity'], identity);
      }
      expect(
        calls
            .where((call) => call.method == 'credentialWrite')
            .single
            .arguments,
        <String, Object?>{'identity': identity, 'secret': '密码 with spaces'},
      );
    },
  );

  test(
    'native picker and Keychain failures propagate instead of looking absent',
    () async {
      respond = (_) async => throw PlatformException(code: 'platform_error');
      await expectLater(platform.pick(), throwsA(isA<PlatformException>()));
      await expectLater(
        platform.read(settings),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        platform.hasSavedCredential(settings),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        platform.write(settings, 'secret'),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        platform.delete(settings),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'desktop database paths survive reopen and reject missing native results',
    () async {
      final path = '${directory.path}/应用 数据/state.sqlite';
      await File(path).parent.create(recursive: true);
      respond = (_) async => path;
      expect(await platform.databasePath(), path);
      final state = SqliteStateStore(path);
      await state.open();
      state.saveSettings(<String, String>{
        'local_root': settings.localRoot,
      }, identityChanged: false);
      state.close();
      final reopened = SqliteStateStore(await platform.databasePath());
      await reopened.open();
      expect(reopened.loadSettings()['local_root'], settings.localRoot);
      reopened.close();
      respond = (_) async => '';
      await expectLater(platform.databasePath(), throwsA(isA<SyncFailure>()));
      respond = (_) async => throw PlatformException(code: 'platform_error');
      await expectLater(
        platform.databasePath(),
        throwsA(isA<PlatformException>()),
      );
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'desktop scan and music management use reparse checks only on Windows',
    () async {
      respond = (_) async => false;
      final song = await File('${settings.localRoot}/中文 song.mp3')
          .writeAsString('song');
      final store = platform.createLocalStore() as ConfigurableLocalStore;
      store.configure(settings);
      expect(
        (await store.scan(CancellationToken())).files.single.path.value,
        '中文 song.mp3',
      );
      final tracks = await platform.listMusic(settings);
      expect(tracks.single.path.value, '中文 song.mp3');
      await platform.deleteMusic(settings, tracks.single);
      expect(await song.exists(), isFalse);
      expect(
        calls.where((call) => call.method == 'isReparsePoint').isNotEmpty,
        Platform.isWindows,
      );
    },
    skip: Platform.isAndroid,
  );

  test('macOS ignores symlinks during scans and music listing', () async {
    final outside = await File('${directory.path}/outside.mp3')
        .writeAsString('outside');
    await Link('${settings.localRoot}/linked.mp3').create(outside.path);
    final store = platform.createLocalStore() as ConfigurableLocalStore;
    store.configure(settings);
    expect((await store.scan(CancellationToken())).files, isEmpty);
    expect(await platform.listMusic(settings), isEmpty);
    expect(calls, isEmpty);
    expect(await outside.readAsString(), 'outside');
  }, skip: !Platform.isMacOS);

  test(
    'repeated close requests wait for cancellation and host cleanup once',
    () async {
      final state = SqliteStateStore('${directory.path}/close.sqlite');
      await state.open();
      final host = _BlockingHost();
      respond = (call) async =>
          call.method == 'credentialRead' ? 'secret' : null;
      final controller = SyncController(
        engine: SyncEngine(
          localStore: platform.createLocalStore(),
          webDav: WebDavClient(),
          stateStore: state,
        ),
        credentials: platform,
        executionHost: host,
      );
      platform.bind(controller);
      try {
        final running = controller.start(settings);
        await host.started.future;
        final first = _callback(channel, 'windowCloseRequested');
        final second = _callback(channel, 'windowCloseRequested');
        await Future<void>.delayed(Duration.zero);
        expect(
          calls.where((call) => call.method == 'allowWindowClose'),
          isEmpty,
        );
        host.releaseStart.complete();
        await host.finishing.future;
        expect(controller.progress.phase, SyncPhase.cancelled);
        expect(
          calls.where((call) => call.method == 'allowWindowClose'),
          isEmpty,
        );
        host.releaseFinish.complete();
        await Future.wait(<Future<Object?>>[first, second, running]);
        expect(controller.isRunning, isFalse);
        expect(
          calls.where((call) => call.method == 'allowWindowClose'),
          hasLength(1),
        );
      } finally {
        if (!host.releaseStart.isCompleted) host.releaseStart.complete();
        if (!host.releaseFinish.isCompleted) host.releaseFinish.complete();
        await controller.cancelAndWait();
        controller.dispose();
        state.close();
      }
    },
  );

  test('a failed close acknowledgement can be retried', () async {
    final state = SqliteStateStore('${directory.path}/retry.sqlite');
    await state.open();
    final controller = SyncController(
      engine: SyncEngine(
        localStore: platform.createLocalStore(),
        webDav: WebDavClient(),
        stateStore: state,
      ),
      credentials: platform,
      executionHost: platform,
    );
    platform.bind(controller);
    try {
      respond = (_) async => throw PlatformException(code: 'platform_error');
      await expectLater(
        _callback(channel, 'windowCloseRequested'),
        throwsA(isA<PlatformException>()),
      );
      respond = (_) async => null;
      await _callback(channel, 'windowCloseRequested');
      expect(
        calls.where((call) => call.method == 'allowWindowClose'),
        hasLength(2),
      );
    } finally {
      controller.dispose();
      state.close();
    }
  });
}

Future<Object?> _callback(MethodChannel channel, String method) {
  final result = Completer<Object?>();
  ui.channelBuffers.push(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall(method)),
    (data) {
      try {
        result.complete(
          data == null ? null : channel.codec.decodeEnvelope(data),
        );
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    },
  );
  return result.future;
}

final class _BlockingHost implements SyncExecutionHost {
  final started = Completer<void>();
  final releaseStart = Completer<void>();
  final finishing = Completer<void>();
  final releaseFinish = Completer<void>();
  @override
  Future<void> start(SyncSettings settings) async {
    started.complete();
    await releaseStart.future;
  }

  @override
  Future<void> update(SyncProgress progress) async {}
  @override
  Future<void> finish(SyncProgress progress) async {
    finishing.complete();
    await releaseFinish.future;
  }
}
