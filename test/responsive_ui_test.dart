import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synctune/app/design/sync_theme.dart';
import 'package:synctune/app/shell/sync_tune_shell.dart';

void main() {
  for (final width in <double>[320, 599, 600, 999, 1000]) {
    testWidgets('all modules remain usable at 200% text, $width px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const ProviderScope(child: SyncTuneShell()),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final scaffold = find.byType(Scaffold).first;
      final scaler = MediaQuery.of(tester.element(scaffold)).textScaler;
      expect(scaler.scale(10), 20);

      for (final icon in <IconData>[
        Icons.sync_outlined,
        Icons.settings_outlined,
        Icons.library_music_outlined,
      ]) {
        await tester.tap(find.byIcon(icon).first);
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await tester.binding.setSurfaceSize(null);
    });
  }

  testWidgets('composition initialization failures are visible in the shell', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: SyncTuneShell(initializationMessage: '本地数据服务初始化失败'),
      ),
    );
    await tester.pump();

    expect(find.text('本地服务初始化未完成'), findsOneWidget);
    expect(find.text('本地数据服务初始化失败'), findsOneWidget);
  });

  for (final platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('themed controls keep a 48px hit target on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: syncTuneLightTheme(),
            home: Scaffold(
              body: Wrap(
                children: [
                  FilledButton(onPressed: () {}, child: const Text('填充')),
                  OutlinedButton(onPressed: () {}, child: const Text('描边')),
                  IconButton(onPressed: () {}, icon: const Icon(Icons.star)),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.getSize(find.byType(FilledButton)).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.byType(OutlinedButton)).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.byType(IconButton)).height,
          greaterThanOrEqualTo(48),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
