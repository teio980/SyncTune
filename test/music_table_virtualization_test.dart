import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/music/music_scan.dart';
import 'package:synctune/app/music/music_scan_port.dart';
import 'package:synctune/app/shell/sync_tune_shell.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';

final class _FakeScanner implements MusicScannerPort {
  @override
  Future<Map<Object?, Object?>> scan(RootGrant grant) async => {
    'status': 'ok',
    'generation': grant.generation,
    'complete': true,
    'items': [
      for (var index = 0; index < 500; index++)
        <Object?, Object?>{
          'id': 'entry-$index',
          'relativePath': 'album/track-$index.mp3',
          'size': index + 1,
          'extension': 'mp3',
        },
    ],
  };
}

final class _LongPathScanner implements MusicScannerPort {
  @override
  Future<Map<Object?, Object?>> scan(RootGrant grant) async => {
    'status': 'ok',
    'generation': grant.generation,
    'complete': true,
    'items': [
      for (var index = 0; index < 500; index++)
        <Object?, Object?>{
          'id': 'long-entry-$index',
          'relativePath':
              'very-long-album-name-that-wraps/track-$index-with-a-long-name.mp3',
          'size': 2 * 1024 * 1024 * 1024 + index,
          'extension': 'mp3',
        },
    ],
  };
}

Future<ProviderContainer> _preparedContainer([
  MusicScannerPort? scanner,
]) async {
  final container = ProviderContainer(
    overrides: [
      musicScannerPortProvider.overrideWithValue(scanner ?? _FakeScanner()),
    ],
  );
  const grant = RootGrant(
    path: 'authorized',
    token: 'token',
    generation: 'generation',
  );
  container.read(rootGrantProvider.notifier).setGrant(grant);
  await container.read(musicScanProvider.notifier).scan(grant);
  return container;
}

void main() {
  testWidgets('expanded viewport renders a virtualized song table', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    final container = await _preparedContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SyncTuneShell(),
      ),
    );
    await tester.pump();
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('格式'), findsOneWidget);
    expect(find.text('大小'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('album/track-0.mp3'), findsOneWidget);
    expect(find.text('album/track-499.mp3'), findsNothing);

    for (
      var index = 0;
      index < 60 && find.text('album/track-499.mp3').evaluate().isEmpty;
      index++
    ) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pump();
    }
    expect(find.text('album/track-499.mp3'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('favorite controls are disabled without a favorite port', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 800));
    final container = await _preparedContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SyncTuneShell(),
      ),
    );
    await tester.pump();

    final favorite = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byIcon(Icons.star_border).first,
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(favorite.onPressed, isNull);
    expect(favorite.tooltip, '收藏服务尚未连接');
    await tester.binding.setSurfaceSize(null);
  });

  for (final width in <double>[320, 1000]) {
    testWidgets('long paths and large sizes remain usable at 200%, $width px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      final container = await _preparedContainer(_LongPathScanner());
      addTearDown(container.dispose);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: UncontrolledProviderScope(
            container: container,
            child: const SyncTuneShell(),
          ),
        ),
      );
      await tester.pump();
      expect(
        MediaQuery.of(tester.element(find.byType(Scaffold).first)).textScaler
            .scale(10),
        20,
      );
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    });
  }
}
