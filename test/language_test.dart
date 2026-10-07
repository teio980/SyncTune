import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/localization/language.dart';
import 'package:synctune/app/shell/sync_tune_shell.dart';
import 'package:synctune/app/settings/settings_view_model.dart';
import 'package:synctune/data/sync_tune_database.dart';
import 'package:synctune/infrastructure/composition/synctune_composition.dart';

class _LanguagePort implements LanguagePreferencePort {
  AppLanguage stored = AppLanguage.english;
  Completer<AppLanguage>? pendingLoad;
  Completer<void>? pendingSave;
  bool failSave = false;
  final saves = <AppLanguage>[];
  @override
  Future<AppLanguage> load() async => pendingLoad?.future ?? stored;
  @override
  Future<void> save(AppLanguage language) async {
    saves.add(language);
    if (pendingSave != null) await pendingSave!.future;
    if (failSave) throw StateError('storage unavailable');
    stored = language;
  }
}

class _FailedConnection implements WebDavConnectionCheckPort {
  @override
  Future<void> check(WebDavSettings settings) async =>
      throw const WebDavConnectionCheckException(
        'Authentication failed. Check your username and password.',
      );
}

void main() {
  testWidgets('connection errors retranslate without losing form edits', (
    tester,
  ) async {
    final languagePort = _LanguagePort()..stored = AppLanguage.chinese;
    final container = ProviderContainer(
      overrides: [
        languagePreferencePortProvider.overrideWithValue(languagePort),
        webDavConnectionCheckPortProvider.overrideWithValue(
          _FailedConnection(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final settings = container.read(webDavSettingsProvider.notifier);
    settings.setEndpoint('https://example.com/music');
    settings.setUsername('user');
    settings.setPassword('password');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SyncTuneShell(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final check = find.text('检查连接状态');
    await Scrollable.ensureVisible(tester.element(check), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(check);
    await tester.pumpAndSettle();
    expect(find.text('连接检查失败'), findsOneWidget);
    expect(find.text('认证失败，请检查用户名和密码。'), findsOneWidget);
    await container.read(languageProvider.notifier).select(AppLanguage.english);
    await tester.pumpAndSettle();
    expect(find.text('Connection check failed'), findsOneWidget);
    expect(
      find.text('Authentication failed. Check your username and password.'),
      findsOneWidget,
    );
    expect(container.read(webDavSettingsProvider).settings.username, 'user');
    expect(
      container.read(webDavSettingsProvider).settings.password,
      'password',
    );
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.map((field) => field.controller!.text), [
      'https://example.com/music',
      'user',
      'password',
    ]);
    expect(tester.takeException(), isNull);
  });
  test('English is the default and unknown saved codes fall back to it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(languageProvider).language, AppLanguage.english);
    expect(AppLanguage.fromCode('fr'), AppLanguage.english);
    expect(AppLanguage.fromCode(null), AppLanguage.english);
    expect(AppLanguage.fromCode('en'), AppLanguage.english);
    expect(AppLanguage.fromCode('zh'), AppLanguage.chinese);
  });
  test('a late load cannot overwrite a selection and writes preserve selection order', () async {
    final port = _LanguagePort()
      ..pendingLoad = Completer<AppLanguage>()
      ..pendingSave = Completer<void>();
    final container = ProviderContainer(
      overrides: [languagePreferencePortProvider.overrideWithValue(port)],
    );
    addTearDown(container.dispose);
    final model = container.read(languageProvider.notifier);
    final first = model.select(AppLanguage.chinese);
    final second = model.select(AppLanguage.english);
    port.pendingLoad!.complete(AppLanguage.chinese);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(languageProvider).language, AppLanguage.english);
    expect(port.saves, [AppLanguage.chinese]);
    port.pendingSave!.complete();
    await Future.wait([first, second]);
    expect(port.saves, [AppLanguage.chinese, AppLanguage.english]);
    expect(port.stored, AppLanguage.english);
  });
  test(
    'save failure keeps the chosen language and a later selection can recover',
    () async {
      final port = _LanguagePort()..failSave = true;
      final container = ProviderContainer(
        overrides: [languagePreferencePortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      final model = container.read(languageProvider.notifier);
      await model.select(AppLanguage.chinese);
      expect(container.read(languageProvider).language, AppLanguage.chinese);
      expect(container.read(languageProvider).saveFailed, isTrue);
      port.failSave = false;
      await model.select(AppLanguage.english);
      expect(container.read(languageProvider).saveFailed, isFalse);
      expect(port.stored, AppLanguage.english);
    },
  );
  test(
    'the real database restores the language after closing and reopening',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'synctune-language-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/preferences.sqlite');
      final database = SyncTuneDatabase(NativeDatabase(file));
      await DatabaseLanguagePreferencePort(database).save(AppLanguage.chinese);
      await database.close();
      final reopened = SyncTuneDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      final container = ProviderContainer(
        overrides: [
          languagePreferencePortProvider.overrideWithValue(
            DatabaseLanguagePreferencePort(reopened),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(languageProvider);
      expect(
        await DatabaseLanguagePreferencePort(reopened).load(),
        AppLanguage.chinese,
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(languageProvider).language, AppLanguage.chinese);
    },
  );
  testWidgets(
    'Settings switches both ways and retranslates an existing warning',
    (tester) async {
      final port = _LanguagePort();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [languagePreferencePortProvider.overrideWithValue(port)],
          child: const SyncTuneShell(
            initializationMessage:
                'Sync service initialization failed. Sync remains disabled.',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      final selector = find.byType(DropdownButtonFormField<AppLanguage>);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chinese').last);
      await tester.pumpAndSettle();
      expect(port.stored, AppLanguage.chinese);
      expect(find.text('语言'), findsOneWidget);
      expect(find.text('同步服务初始化失败，同步保持禁用。'), findsOneWidget);
      expect(
        Localizations.localeOf(tester.element(find.byType(Scaffold).first))
            .languageCode,
        'zh',
      );
      await tester.tap(find.byIcon(Icons.library_music_outlined));
      await tester.pumpAndSettle();
      expect(find.text('尚未选择音乐根目录'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.sync_outlined));
      await tester.pumpAndSettle();
      expect(find.text('同步状态'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('英文').last);
      await tester.pumpAndSettle();
      expect(port.stored, AppLanguage.english);
      expect(find.text('Language'), findsOneWidget);
      expect(
        find.text('Sync service initialization failed. Sync remains disabled.'),
        findsOneWidget,
      );
      for (final widget in tester.widgetList<Text>(find.byType(Text))) {
        expect(widget.data ?? '', isNot(matches(RegExp(r'[\u3400-\u9fff]'))));
      }
      expect(tester.takeException(), isNull);
    },
  );
  for (final language in AppLanguage.values) {
    for (final width in [320.0, 1000.0]) {
      testWidgets('$language screens fit at 200% text and $width px', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final port = _LanguagePort()..stored = language;
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: ProviderScope(
              overrides: [
                languagePreferencePortProvider.overrideWithValue(port),
              ],
              child: const SyncTuneShell(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final icon in [
          Icons.settings_outlined,
          Icons.sync_outlined,
          Icons.library_music_outlined,
        ]) {
          await tester.tap(find.byIcon(icon).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
