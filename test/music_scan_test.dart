import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:synctune/app/music/music_scan.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const grant = RootGrant(
    path: 'authorized',
    token: 'token-a',
    generation: 'generation-a',
  );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(musicScanChannel, null);
  });

  test(
    'accepts only normalized relative music paths and matching extensions',
    () {
      final track = MusicTrack.fromMap(<Object?, Object?>{
        'relativePath': 'albums/song.mp3',
        'size': 42,
        'extension': 'mp3',
      });
      expect(track.relativePath, 'albums/song.mp3');

      for (final path in <String>[
        'C:/outside.mp3',
        'folder:stream.mp3',
        'CON.mp3',
        '../outside.mp3',
        'albums\\song.mp3',
      ]) {
        expect(
          () => MusicTrack.fromMap(<Object?, Object?>{
            'relativePath': path,
            'size': 1,
            'extension': 'mp3',
          }),
          throwsFormatException,
        );
      }
      expect(
        () => MusicTrack.fromMap(<Object?, Object?>{
          'relativePath': 'song.mp3',
          'size': 1,
          'extension': 'flac',
        }),
        throwsFormatException,
      );
    },
  );

  test('rejects a stale root before invoking the native scanner', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(musicScanChannel, (call) async {
          calls++;
          return <String, Object?>{'status': 'ok', 'items': <Object?>[]};
        });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final roots = container.read(rootGrantProvider.notifier);
    roots.setGrant(grant);
    await container
        .read(musicScanProvider.notifier)
        .scan(
          const RootGrant(
            path: 'old',
            token: 'old-token',
            generation: 'old-generation',
          ),
        );
    expect(calls, 0);
    expect(container.read(musicScanProvider).status, MusicScanStatus.failed);
  });

  test('ignores a scan result after the provider is disposed', () async {
    final response = Completer<Map<Object?, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(musicScanChannel, (call) => response.future);
    final container = ProviderContainer();
    final roots = container.read(rootGrantProvider.notifier);
    roots.setGrant(grant);
    final scan = container.read(musicScanProvider.notifier).scan(grant);
    container.dispose();
    response.complete(<String, Object?>{
      'status': 'ok',
      'generation': 'generation-a',
      'complete': true,
      'items': <Object?>[],
    });
    await scan;
  });
}
