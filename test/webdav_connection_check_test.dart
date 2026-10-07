import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/design/sync_theme.dart';
import 'package:synctune/app/localization/strings.dart';
import 'package:synctune/app/settings/settings_page.dart';
import 'package:synctune/app/settings/settings_view_model.dart';
import 'package:synctune/infrastructure/network/webdav_connection_checker.dart';

const _settings = WebDavSettings(
  endpoint: 'https://dav.example/music',
  username: 'user',
  password: 'draft-password',
);

const _collection = '''
<d:multistatus xmlns:d="DAV:"><d:response>
  <d:href>/music/</d:href><d:propstat>
    <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
</d:response></d:multistatus>
''';

void main() {
  test(
    'checks draft credentials with one read-only, depth-zero request',
    () async {
      final adapter = _Adapter(_collection, 207);
      await _checker(adapter).check(_settings);

      final request = adapter.requests.single;
      expect(request.uri.toString(), 'https://dav.example/music/');
      expect(request.method, 'PROPFIND');
      expect(request.headers['Depth'], '0');
      expect(
        request.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('user:draft-password'))}',
      );
      expect(request.followRedirects, isFalse);
      expect(request.connectTimeout, const Duration(seconds: 10));
      expect(adapter.closed, isTrue);
    },
  );

  for (final entry in {
    401: 'Authentication failed',
    403: 'Access denied',
    404: 'folder was not found',
    405: 'does not support WebDAV',
    302: 'redirected',
    500: 'unexpected response',
  }.entries) {
    test(
      'HTTP ${entry.key} reports a useful failure and closes transport',
      () async {
        final adapter = _Adapter('private server response', entry.key);
        await expectLater(
          _checker(adapter).check(_settings),
          throwsA(
            isA<WebDavConnectionCheckException>().having(
              (error) => error.message,
              'message',
              contains(entry.value),
            ),
          ),
        );
        expect(adapter.requests, hasLength(1));
        expect(adapter.closed, isTrue);
      },
    );
  }

  for (final response in {
    'HTML login page': '<html>Login</html>',
    'empty multistatus': '<d:multistatus xmlns:d="DAV:"/>',
    'denied property access': _collection.replaceAll('200 OK', '403 Forbidden'),
    'file resource': _collection.replaceAll('<d:collection/>', ''),
    'different host': _collection.replaceAll(
      '/music/',
      'https://other.example/music/',
    ),
    'different folder': _collection.replaceAll('/music/', '/another-folder/'),
  }.entries) {
    test('rejects a 207 response with ${response.key}', () async {
      await expectLater(
        _checker(_Adapter(response.value, 207)).check(_settings),
        throwsA(isA<WebDavConnectionCheckException>()),
      );
    });
  }

  test('invalid endpoints never create a transport', () async {
    var created = false;
    final checker = WebDavConnectionChecker(
      dioFactory: (_) {
        created = true;
        return Dio();
      },
    );
    await expectLater(
      checker.check(const WebDavSettings(endpoint: 'http://dav.example/music')),
      throwsA(isA<WebDavConnectionCheckException>()),
    );
    expect(created, isFalse);
  });

  test('transport failures hide private details and report timeout', () async {
    final adapter = _Adapter(_collection, 207)
      ..errorType = DioExceptionType.receiveTimeout;
    await expectLater(
      _checker(adapter).check(_settings),
      throwsA(
        isA<WebDavConnectionCheckException>().having(
          (error) => error.message,
          'message',
          'The connection timed out. Check the server and try again.',
        ),
      ),
    );
    expect(adapter.closed, isTrue);
  });

  test(
    'saved passwords are reused only for the same account unless cleared',
    () async {
      final loader = _Loader(_settings);
      for (final entry in [
        (
          const WebDavSettings(
            endpoint: 'https://dav.example/music/',
            username: 'user',
          ),
          'user:draft-password',
        ),
        (
          const WebDavSettings(
            endpoint: 'https://dav.example/music/',
            username: 'other',
          ),
          'other:',
        ),
        (
          const WebDavSettings(
            endpoint: 'https://dav.example/music/',
            username: 'user',
            clearPassword: true,
          ),
          'user:',
        ),
        (
          const WebDavSettings(
            endpoint: 'https://dav.example/different/',
            username: 'user',
          ),
          'user:',
        ),
      ]) {
        final path = Uri.parse(entry.$1.endpoint).path;
        final adapter = _Adapter(_collection.replaceAll('/music/', path), 207);
        await _checker(adapter, loader: loader).check(entry.$1);
        expect(
          adapter.requests.single.headers['Authorization'],
          'Basic ${base64Encode(utf8.encode(entry.$2))}',
        );
      }
      expect(loader.calls, 3);
    },
  );

  test(
    'connection checks preserve save status and ignore duplicate clicks',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final model = container.read(webDavSettingsProvider.notifier);
      model.setEndpoint(_settings.endpoint);
      await model.save(_Save());
      final pending = _PendingCheck();
      final check = model.checkConnection(pending);
      await model.checkConnection(pending);
      expect(pending.calls, 1);
      expect(
        container.read(webDavSettingsProvider).connectionStatus,
        WebDavConnectionStatus.checking,
      );
      pending.complete.complete();
      await check;
      final state = container.read(webDavSettingsProvider);
      expect(state.connectionStatus, WebDavConnectionStatus.connected);
      expect(state.status, WebDavSaveStatus.saved);
      expect(state.message, 'Settings saved');
    },
  );

  for (final fail in [false, true]) {
    test(
      'editing credentials discards an older ${fail ? 'failed' : 'successful'} check',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final model = container.read(webDavSettingsProvider.notifier);
        model.setEndpoint(_settings.endpoint);
        final pending = _PendingCheck();
        final check = model.checkConnection(pending);
        model.setPassword('new-password');
        if (fail) {
          pending.complete.completeError(StateError('old failure'));
        } else {
          pending.complete.complete();
        }
        await check;
        final state = container.read(webDavSettingsProvider);
        expect(state.connectionStatus, WebDavConnectionStatus.idle);
        expect(state.connectionMessage, isNull);
        expect(state.settings.password, 'new-password');
      },
    );
  }

  test('a pending check may finish after the provider is disposed', () async {
    final container = ProviderContainer();
    final model = container.read(webDavSettingsProvider.notifier);
    model.setEndpoint(_settings.endpoint);
    final pending = _PendingCheck();
    final check = model.checkConnection(pending);
    container.dispose();
    pending.complete.complete();
    await expectLater(check, completes);
  });

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets(
      'connection button shows progress and success in ${locale.languageCode}',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            webDavSettingsPortProvider.overrideWithValue(_Save()),
            webDavConnectionCheckPortProvider.overrideWithValue(
              _PendingCheck(),
            ),
          ],
        );
        addTearDown(container.dispose);
        final model = container.read(webDavSettingsProvider.notifier);
        model.setEndpoint(_settings.endpoint);
        model.setUsername(_settings.username);
        model.setPassword(_settings.password);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: locale,
              supportedLocales: SyncTuneStrings.supportedLocales,
              localizationsDelegates: const [
                SyncTuneStrings.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: syncTuneLightTheme(),
              home: const Scaffold(
                body: SettingsPage(onPickRoot: null, diagnosticsBuilder: null),
              ),
            ),
          ),
        );
        final strings = SyncTuneStrings(locale);
        if (locale.languageCode == 'zh') {
          expect(strings.text('Check connection status'), '检查连接状态');
          expect(strings.text('Checking connection…'), '正在检查连接…');
          expect(strings.text('Connection successful'), '连接成功');
        }
        final button = find.widgetWithText(
          OutlinedButton,
          strings.text('Check connection status'),
        );
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pump();
        expect(find.text(strings.text('Checking connection…')), findsWidgets);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(
                  OutlinedButton,
                  strings.text('Checking connection…'),
                ),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(
                  FilledButton,
                  strings.text('Save WebDAV settings'),
                ),
              )
              .onPressed,
          isNull,
        );
        final pending =
            container.read(webDavConnectionCheckPortProvider) as _PendingCheck;
        expect(pending.settings?.password, _settings.password);
        pending.complete.complete();
        await tester.pumpAndSettle();
        expect(
          find.text(strings.text('Connection successful')),
          findsOneWidget,
        );
        expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

WebDavConnectionChecker _checker(
  _Adapter adapter, {
  WebDavSettingsLoader? loader,
}) => WebDavConnectionChecker(
  savedSettings: loader,
  dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
);

final class _Adapter implements HttpClientAdapter {
  _Adapter(this.body, this.status);
  final String body;
  final int status;
  final requests = <RequestOptions>[];
  DioExceptionType? errorType;
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (errorType != null) {
      throw DioException(
        requestOptions: options,
        type: errorType!,
        message: 'private transport details',
      );
    }
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        'content-type': ['application/xml'],
      },
    );
  }

  @override
  void close({bool force = false}) => closed = true;
}

final class _Loader implements WebDavSettingsLoader {
  _Loader(this.settings);
  final WebDavSettings settings;
  int calls = 0;
  @override
  Future<WebDavSettings> load() async {
    calls++;
    return settings;
  }
}

final class _PendingCheck implements WebDavConnectionCheckPort {
  final complete = Completer<void>();
  int calls = 0;
  WebDavSettings? settings;
  @override
  Future<void> check(WebDavSettings settings) {
    calls++;
    this.settings = settings;
    return complete.future;
  }
}

final class _Save implements WebDavSettingsPort {
  @override
  Future<void> save(WebDavSettings settings) async {}
}
