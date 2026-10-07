// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:synctune/main.dart';
import 'package:synctune/app/shell/sync_tune_shell.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';

void main() {
  testWidgets('renders the Windows capability probe', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProbeApp());

    expect(find.text('SyncTune AppContainer Probe'), findsOneWidget);
    expect(find.text('Choose authorized folder'), findsOneWidget);
  });

  testWidgets(
    'default shell exposes Chinese modules and blocks unverified sync',
    (WidgetTester tester) async {
      await tester.pumpWidget(const ProviderScope(child: SyncTuneShell()));

      expect(find.text('音乐'), findsWidgets);
      expect(find.text('同步'), findsWidgets);
      expect(find.text('设置'), findsWidgets);
      expect(
        Localizations.localeOf(tester.element(find.byType(Scaffold).first))
            .languageCode,
        'zh',
      );
      await tester.tap(find.byIcon(Icons.sync_outlined));
      await tester.pump();
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('shell responds to width and keeps sync disabled after grant', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 800));
    await tester.pumpWidget(
      ProviderScope(
        child: SyncTuneShell(
          onPickRoot: () async => const RootGrant(
            path: 'test-root',
            token: 'opaque-token',
            generation: 'test-generation',
          ),
        ),
      ),
    );
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.tap(find.text('选择音乐根目录'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.sync_outlined));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pump();
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('shell restores a root without exposing an async error', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: SyncTuneShell(onRestoreRoot: _restoredRoot)),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    expect(find.textContaining('restored-root'), findsOneWidget);
  });
}

Future<RootGrant?> _restoredRoot() async => const RootGrant(
  path: 'restored-root',
  token: 'restored-token',
  generation: 'restored-generation',
);
