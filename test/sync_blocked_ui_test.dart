import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/music/music_scan.dart';
import 'package:synctune/app/music/music_scan_port.dart';
import 'package:synctune/app/sync/sync_gate.dart';
import 'package:synctune/app/sync/sync_page.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

const _blocked = SyncGateState(
  status: SyncGateStatus.unavailable,
  title: 'Platform requirements not met',
  message: 'Local file safety requirements have not been verified. Sync is currently unavailable.',
);

final class _CompleteScanner implements MusicScannerPort {
  @override
  Future<Map<Object?, Object?>> scan(RootGrant grant) async => {
    'status': 'ok',
    'generation': grant.generation,
    'complete': true,
    'items': <Object?>[],
  };
}

final class _BlockedRuntime
    implements SyncRuntimePort, SyncRuntimeControls, RemoteMusicImportControls {
  SyncGateState nextCheck = _blocked;
  int retries = 0;
  int imports = 0;
  int checks = 0;
  Stream<ForegroundRuntimeSnapshot> updates = const Stream.empty();

  @override
  Future<void> importCloudMusic() async {
    imports++;
    snapshot = const ForegroundRuntimeSnapshot(
      phase: ForegroundRunPhase.succeeded,
      message: 'Sync complete',
    );
  }

  @override
  ForegroundRuntimeSnapshot snapshot = const ForegroundRuntimeSnapshot(
    phase: ForegroundRunPhase.blocked,
    message: 'Platform file safety verification did not pass. Sync is currently unavailable.',
  );

  @override
  Stream<ForegroundRuntimeSnapshot> get snapshots => updates;

  @override
  Future<SyncGateState> check() async {
    checks++;
    return nextCheck;
  }

  @override
  Future<void> retry() async {
    retries++;
    snapshot = ForegroundRuntimeSnapshot(
      phase: ForegroundRunPhase.blocked,
      message: _blocked.message,
    );
    throw StateError('requirements changed after the check');
  }

  @override
  Future<void> run() => retry();

  @override
  Future<void> requestManual() => retry();

  @override
  Future<void> cancel() async {}
}

Future<ProviderContainer> _preparedContainer(_BlockedRuntime runtime) async {
  final container = ProviderContainer(
    overrides: [
      syncRuntimePortProvider.overrideWithValue(runtime),
      musicScannerPortProvider.overrideWithValue(_CompleteScanner()),
    ],
  );
  const grant = RootGrant(path: 'root', token: 'root', generation: 'g1');
  container.read(rootGrantProvider.notifier).setGrant(grant);
  await container.read(musicScanProvider.notifier).scan(grant);
  return container;
}

Future<void> _showPage(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SyncPage())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('live sync replaces stale readiness and renders file progress', (
    tester,
  ) async {
    final events = StreamController<ForegroundRuntimeSnapshot>.broadcast();
    addTearDown(events.close);
    final runtime = _BlockedRuntime()
      ..updates = events.stream
      ..snapshot = ForegroundRuntimeSnapshot(
        phase: ForegroundRunPhase.running,
        message: 'Hashing local music',
        lastStartedAtUtc: DateTime.now().toUtc(),
        progress: const SyncProgress(
          stage: 'Hashing local music',
          path: 'album/song.mp3',
          completedItems: 1,
          totalItems: 3,
          completedBytes: 1024,
          totalBytes: 4096,
        ),
      );
    final container = await _preparedContainer(runtime);
    addTearDown(container.dispose);
    container
        .read(syncGateProvider.notifier)
        .setState(
          const SyncGateState(
            status: SyncGateStatus.ready,
            title: 'Ready to sync',
            message: 'Ready',
          ),
        );
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SyncPage())),
      ),
    );
    await tester.pump();
    expect(find.text('Ready to sync'), findsNothing);
    expect(find.text('Sync in progress'), findsOneWidget);
    expect(find.text('album/song.mp3'), findsOneWidget);
    expect(find.text('Files processed: 1 / 3'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .25,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Check again'),
          )
          .onPressed,
      isNull,
    );
    await container.read(syncGateProvider.notifier).refresh(runtime);
    expect(runtime.checks, 0);

    runtime.snapshot = ForegroundRuntimeSnapshot(
      phase: ForegroundRunPhase.running,
      message: 'Downloading',
      lastStartedAtUtc: runtime.snapshot.lastStartedAtUtc,
      progress: const SyncProgress(
        stage: 'Downloading',
        path: 'new.flac',
        completedItems: 2,
        totalItems: 3,
        completedBytes: 4096,
        totalBytes: 8192,
      ),
    );
    events.add(runtime.snapshot);
    await tester.pump();
    await tester.pump();
    expect(find.text('album/song.mp3'), findsNothing);
    expect(find.text('new.flac'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .5,
    );
    runtime.snapshot = const ForegroundRuntimeSnapshot(
      phase: ForegroundRunPhase.succeeded,
      message: 'Sync complete',
    );
    events.add(runtime.snapshot);
    await tester.pumpAndSettle();
    expect(find.text('Sync complete'), findsWidgets);
    expect(find.text('Cancel sync'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing remote identity offers an explicit import action', (
    tester,
  ) async {
    final runtime = _BlockedRuntime()
      ..snapshot = const ForegroundRuntimeSnapshot(
        phase: ForegroundRunPhase.failed,
        requiresRemoteImport: true,
        message: 'Existing cloud music needs to be imported into SyncTune. Tap Import cloud music, then sync again.',
      )
      ..nextCheck = const SyncGateState(
        status: SyncGateStatus.ready,
        title: 'Ready',
        message: 'Ready',
      );
    final container = await _preparedContainer(runtime);
    addTearDown(container.dispose);
    await _showPage(tester, container);
    expect(runtime.imports, 0);
    expect(find.text('Import cloud music'), findsOneWidget);
    await tester.tap(find.text('Import cloud music'));
    await tester.pumpAndSettle();
    expect(runtime.imports, 1);
    expect(runtime.retries, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the runtime blocker before a manual requirements check', (
    tester,
  ) async {
    final runtime = _BlockedRuntime();
    final container = await _preparedContainer(runtime);
    addTearDown(container.dispose);
    await _showPage(tester, container);

    expect(find.text('Sync blocked'), findsOneWidget);
    expect(find.text(runtime.snapshot.message), findsOneWidget);

    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();

    expect(find.text(_blocked.title), findsOneWidget);
    expect(find.text(_blocked.message), findsOneWidget);
    expect(find.text(runtime.snapshot.message), findsNothing);
  });

  testWidgets('retry reports a rejected check without submitting a run', (
    tester,
  ) async {
    final runtime = _BlockedRuntime();
    final container = await _preparedContainer(runtime);
    addTearDown(container.dispose);
    await _showPage(tester, container);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(runtime.retries, 0);
    expect(find.text(_blocked.title), findsOneWidget);
    expect(find.text(_blocked.message), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry catches a new blocker after a successful check', (
    tester,
  ) async {
    final runtime = _BlockedRuntime()
      ..nextCheck = const SyncGateState(
        status: SyncGateStatus.ready,
        title: 'Ready to sync',
        message: 'Ready',
      );
    final container = await _preparedContainer(runtime);
    addTearDown(container.dispose);
    await _showPage(tester, container);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(runtime.retries, 1);
    expect(find.text('Sync blocked'), findsOneWidget);
    expect(find.text(_blocked.message), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
