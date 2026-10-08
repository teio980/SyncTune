import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/sync_tune_app.dart';
import 'package:synctune/platform/sync_platform_adapters.dart';
import 'package:synctune/sync/state_store.dart';
import 'package:synctune/sync/sync_controller.dart';
import 'package:synctune/sync/sync_engine.dart';
import 'package:synctune/sync/sync_model.dart';
import 'package:synctune/sync/sync_platform.dart';
import 'package:synctune/sync/webdav_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('synctune/sync_platform');

  Future<_Harness> mountApp(
    WidgetTester tester, {
    String remoteRoot = 'Music/synctune',
    Future<String>? credentialRead,
    _RecordingAdapter? adapter,
    List<SyncMusicTrack> initialTracks = const <SyncMusicTrack>[],
  }) async {
    final directory =
        await tester.runAsync(
          () => Directory.systemTemp.createTemp('synctune-ui-'),
        ) ??
        (throw StateError('Could not create the widget-test directory.'));
    final database = SqliteStateStore(
      '${directory.path}${Platform.pathSeparator}state.sqlite',
    );
    await tester.runAsync(database.open);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'credentialExists':
              return true;
            case 'credentialRead':
              return credentialRead ?? 'stored-password';
            case 'isReparsePoint':
              return false;
            default:
              return null;
          }
        });
    final platform = SyncPlatformAdapters(channel: channel);
    final musicLibrary = _MemoryMusicLibrary(initialTracks);
    final settings = SyncSettings(
      localRoot: directory.path,
      localRootId: directory.path,
      localGeneration: 'windows-folder-v2',
      serverUrl: 'https://example.test/dav',
      remoteRoot: remoteRoot,
      username: 'listener',
      language: 'en',
    );
    final controller = SyncController(
      engine: SyncEngine(
        localStore: platform.createLocalStore(),
        webDav: WebDavClient(
          dio: Dio()..httpClientAdapter = adapter ?? _RecordingAdapter(),
        ),
        stateStore: database,
      ),
      credentials: platform,
      executionHost: platform,
    );
    platform.bind(controller);
    final config = ValueNotifier<SyncAppConfig>(
      SyncAppConfig(language: 'en', settings: settings),
    );
    await tester.pumpWidget(
      SyncTuneApp(
        config: config,
        stateStore: database,
        platform: platform,
        controller: controller,
        musicLibrary: musicLibrary,
      ),
    );
    await tester.pumpAndSettle();
    return _Harness(
      directory: directory,
      stateStore: database,
      platform: platform,
      controller: controller,
      config: config,
      adapter: adapter,
      musicLibrary: musicLibrary,
    );
  }

  Future<void> unmountApp(WidgetTester tester, _Harness harness) async {
    await tester.pumpWidget(const SizedBox.shrink());
    harness.controller.dispose();
    harness.stateStore.close();
    harness.config.dispose();
    harness.adapter?.close(force: true);
    await tester.runAsync(() => harness.directory.delete(recursive: true));
    harness.platform.channel.setMethodCallHandler(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Finder textField(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'music navigation, full legacy URL, password visibility and read-only connection test',
    (tester) async {
      final adapter = _RecordingAdapter();
      final harness = await mountApp(tester, adapter: adapter);
      addTearDown(() => unmountApp(tester, harness));

      expect(find.text('Music'), findsWidgets);
      expect(find.text('Sync'), findsOneWidget);
      await openSettings(tester);
      final urlField = tester.widget<TextField>(textField('WebDAV URL'));
      expect(
        urlField.controller!.text,
        'https://example.test/dav/Music/synctune',
      );
      expect(find.text('Remote folder'), findsNothing);
      final passwordField = tester.widget<TextField>(textField('Password'));
      expect(passwordField.controller!.text, 'stored-password');
      expect(passwordField.obscureText, isTrue);
      expect(find.text('Stored in system credentials.'), findsOneWidget);

      await tester.tap(find.byTooltip('Show saved password'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(textField('Password')).obscureText,
        isFalse,
      );
      expect(
        tester.widget<TextField>(textField('Password')).controller!.text,
        'stored-password',
      );
      await tester.tap(find.byTooltip('Hide password'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(textField('Password')).obscureText,
        isTrue,
      );
      expect(
        tester.widget<TextField>(textField('Password')).controller!.text,
        'stored-password',
      );

      await tester.ensureVisible(find.text('Test connection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test connection'));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      expect(adapter.requests, hasLength(1));
      final successMessage = find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data == 'WebDAV connection successful.',
      );
      for (
        var attempt = 0;
        attempt < 20 && successMessage.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(successMessage, findsOneWidget);
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, 'PROPFIND');
      expect(adapter.requests.single.uri.path, '/dav/Music/synctune/');
      expect(adapter.requests.single.headers['Depth'], '0');
    },
  );

  testWidgets(
    'music deletion requires confirmation and removes only the selected local song',
    (tester) async {
      final track = SyncMusicTrack(
        path: SyncPath.parse('song.mp3'),
        size: 3,
        modifiedMs: 10,
      );
      final harness = await mountApp(
        tester,
        initialTracks: <SyncMusicTrack>[track],
      );
      addTearDown(() => unmountApp(tester, harness));

      expect(find.text('song.mp3'), findsWidgets);
      expect(find.text('Delete songs (0)'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete song'));
      await tester.pumpAndSettle();
      expect(find.text('Delete songs?'), findsOneWidget);
      expect(
        find.textContaining(
          'Songs in sync history will also be deleted from WebDAV on the next sync.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Unregistered WebDAV songs may be downloaded again on the first sync.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Delete songs'));
      await tester.pumpAndSettle();
      expect(harness.musicLibrary.deleted, <String>['song.mp3']);
      expect(
        find.text(
          'Deleted selected songs. Songs in sync history will also be deleted from WebDAV on the next sync.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'saved-password reveal is discarded when the account changes during the secure read',
    (tester) async {
      final gate = Completer<String>();
      final harness = await mountApp(tester, credentialRead: gate.future);
      addTearDown(() => unmountApp(tester, harness));
      await openSettings(tester);
      await tester.tap(find.byTooltip('Show saved password'));
      await tester.pump();
      await tester.enterText(
        textField('WebDAV URL'),
        'https://other.test/music',
      );
      gate.complete('old-account-password');
      await tester.pumpAndSettle();

      final password = tester.widget<TextField>(textField('Password'));
      expect(password.controller!.text, isEmpty);
      expect(password.obscureText, isTrue);
    },
  );
}

final class _Harness {
  const _Harness({
    required this.directory,
    required this.stateStore,
    required this.platform,
    required this.controller,
    required this.config,
    required this.musicLibrary,
    this.adapter,
  });
  final Directory directory;
  final SqliteStateStore stateStore;
  final SyncPlatformAdapters platform;
  final SyncController controller;
  final ValueNotifier<SyncAppConfig> config;
  final _MemoryMusicLibrary musicLibrary;
  final _RecordingAdapter? adapter;
}

final class _MemoryMusicLibrary implements SyncMusicLibrary {
  _MemoryMusicLibrary(List<SyncMusicTrack> initial) : tracks = List.of(initial);
  final List<SyncMusicTrack> tracks;
  final List<String> deleted = <String>[];

  @override
  Future<List<SyncMusicTrack>> listMusic(SyncSettings settings) async =>
      List<SyncMusicTrack>.of(tracks);

  @override
  Future<void> deleteMusic(SyncSettings settings, SyncMusicTrack track) async {
    deleted.add(track.path.value);
    tracks.removeWhere((item) => item.path == track.path);
  }
}

final class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final href = options.uri.path;
    return ResponseBody.fromString(
      '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:"><d:response><d:href>$href</d:href>
<d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>''',
      HttpStatus.multiStatus,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
