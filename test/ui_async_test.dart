import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/music/music_scan.dart';
import 'package:synctune/app/sync/sync_gate.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';

final class _PendingRuntime implements SyncRuntimePort {
  final completion = Completer<SyncGateState>();

  @override
  Future<SyncGateState> check() => completion.future;

  @override
  Future<void> run() async {}
}

final class _PendingFavorites implements MusicFavoritesPort {
  final completion = <String, Completer<void>>{};

  @override
  Future<Set<String>> loadFavorites(RootGrant grant) async => <String>{};

  @override
  Future<void> setFavorite({
    required RootGrant grant,
    required MusicTrack track,
    required bool value,
  }) {
    final pending = Completer<void>();
    completion[track.id!] = pending;
    return pending.future;
  }
}

void main() {
  const ready = SyncGateState(
    status: SyncGateStatus.ready,
    title: 'Ready',
    message: 'Ready',
  );

  test('gate invalidation wins over a pending check', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final port = _PendingRuntime();
    final check = container.read(syncGateProvider.notifier).refresh(port);
    container
        .read(syncGateProvider.notifier)
        .setState(const SyncGateState.unavailable());
    port.completion.complete(ready);
    await check;

    expect(container.read(syncGateProvider).status, SyncGateStatus.unavailable);
  });

  test('gate completion after disposal is harmless', () async {
    final container = ProviderContainer();
    final port = _PendingRuntime();
    final check = container.read(syncGateProvider.notifier).refresh(port);
    container.dispose();
    port.completion.complete(ready);

    await expectLater(check, completes);
  });

  test('favorite write failures only roll back their own track', () async {
    final port = _PendingFavorites();
    final container = ProviderContainer(
      overrides: [musicFavoritesPortProvider.overrideWithValue(port)],
    );
    addTearDown(container.dispose);
    const grant = RootGrant(
      path: 'root',
      token: 'token',
      generation: 'generation',
    );
    final model = container.read(musicFavoritesProvider.notifier);
    final a = model.toggleTrack(
      const MusicTrack(
        id: 'entry-a',
        relativePath: 'a.mp3',
        size: 3,
        extension: 'mp3',
      ),
      grant: grant,
    );
    final b = model.toggleTrack(
      const MusicTrack(
        id: 'entry-b',
        relativePath: 'b.mp3',
        size: 3,
        extension: 'mp3',
      ),
      grant: grant,
    );
    port.completion['entry-b']!.complete();
    await b;
    port.completion['entry-a']!.completeError(StateError('persistence failed'));
    await a;

    expect(container.read(musicFavoritesProvider), <String>{'entry-b'});
    expect(container.read(musicFavoritesMessageProvider), '收藏保存失败，请稍后重试。');
  });
}
