import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import 'sync_status_view_model.dart';

enum SyncGateStatus { unavailable, ready, busy, failed }

final class SyncGateState {
  const SyncGateState({
    required this.status,
    required this.title,
    required this.message,
  });

  const SyncGateState.unavailable()
    : status = SyncGateStatus.unavailable,
      title = 'Sync unavailable',
      message =
          'Sync requires verified platform access, remote compatibility, and sync services.';

  final SyncGateStatus status;
  final String title;
  final String message;

  bool get canRun => status == SyncGateStatus.ready;
  bool get isBusy => status == SyncGateStatus.busy;
}

/// The app layer only depends on this port. A platform/data composition root
/// may override it once all local, SAF/AppContainer, and remote gates pass.
abstract interface class SyncRuntimePort {
  Future<SyncGateState> check();

  Future<void> run();
}

/// The foreground scheduler exposes this small UI facing state contract.
/// Keeping it in the app layer lets the sync page render cancellation and
/// retry actions without importing a concrete runtime implementation.
enum ForegroundRunPhase {
  idle,
  scheduled,
  checking,
  running,
  cancelling,
  succeeded,
  blocked,
  failed,
  cancelled,
}

final class ForegroundRuntimeSnapshot {
  const ForegroundRuntimeSnapshot({
    required this.phase,
    required this.message,
    this.runToken,
    this.lastStartedAtUtc,
    this.requiresRemoteImport = false,
    this.progress,
    this.lastProgressAtUtc,
  });

  const ForegroundRuntimeSnapshot.idle()
    : phase = ForegroundRunPhase.idle,
      message = 'Waiting to sync',
      runToken = null,
      requiresRemoteImport = false,
      progress = null,
      lastProgressAtUtc = null,
      lastStartedAtUtc = null;

  final ForegroundRunPhase phase;
  final String message;
  final String? runToken;
  final DateTime? lastStartedAtUtc;
  final bool requiresRemoteImport;
  final SyncProgress? progress;
  final DateTime? lastProgressAtUtc;

  bool get isRunning =>
      phase == ForegroundRunPhase.checking ||
      phase == ForegroundRunPhase.running ||
      phase == ForegroundRunPhase.cancelling;

  bool get canRetry =>
      phase == ForegroundRunPhase.failed ||
      phase == ForegroundRunPhase.cancelled ||
      phase == ForegroundRunPhase.blocked;
}

abstract interface class SyncRuntimeControls {
  ForegroundRuntimeSnapshot get snapshot;

  Stream<ForegroundRuntimeSnapshot> get snapshots;

  Future<void> requestManual();

  Future<void> retry();

  Future<void> cancel();
}

abstract interface class RemoteMusicImportControls {
  Future<void> importCloudMusic();
}

final syncRuntimeSnapshotProvider = StreamProvider<ForegroundRuntimeSnapshot>((
  ref,
) {
  final runtime = ref.watch(syncRuntimePortProvider);
  if (runtime is SyncRuntimeControls) {
    return _runtimeSnapshots(runtime as SyncRuntimeControls);
  }
  return Stream<ForegroundRuntimeSnapshot>.value(
    const ForegroundRuntimeSnapshot.idle(),
  );
});

Stream<ForegroundRuntimeSnapshot> _runtimeSnapshots(
  SyncRuntimeControls runtime,
) {
  return Stream.multi((controller) {
    // Subscribe before reading the initial value so a fast run cannot emit
    // its next phase between the initial yield and stream subscription.
    final subscription = runtime.snapshots.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.add(runtime.snapshot);
    controller.onCancel = subscription.cancel;
  });
}

final syncRuntimePortProvider = Provider<SyncRuntimePort?>((ref) => null);

final class SyncGateViewModel extends Notifier<SyncGateState> {
  int _request = 0;
  bool _disposed = false;

  @override
  SyncGateState build() {
    ref.onDispose(() => _disposed = true);
    ref.listen<RootGrant?>(rootGrantProvider, (previous, next) {
      if (previous?.token == next?.token &&
          previous?.generation == next?.generation) {
        return;
      }
      invalidate();
    });
    return const SyncGateState.unavailable();
  }

  void invalidate([SyncGateState next = const SyncGateState.unavailable()]) {
    _request++;
    if (_disposed) return;
    state = next;
  }

  void setState(SyncGateState next) => invalidate(next);

  Future<void> refresh(SyncRuntimePort? port) async {
    if (port is SyncRuntimeControls &&
        (port as SyncRuntimeControls).snapshot.isRunning) {
      return;
    }
    final request = ++_request;
    if (_disposed) return;
    if (port == null) {
      if (_disposed || request != _request) return;
      state = const SyncGateState.unavailable();
      return;
    }
    state = const SyncGateState(
      status: SyncGateStatus.busy,
      title: 'Checking sync requirements',
      message: '',
    );
    try {
      final next = await port.check();
      if (_disposed || request != _request) return;
      state = next;
    } catch (_) {
      if (_disposed || request != _request) return;
      state = const SyncGateState(
        status: SyncGateStatus.failed,
        title: 'Sync requirements check failed',
        message: 'Check the connection and folder access, then retry.',
      );
    }
  }

  Future<void> run(SyncRuntimePort? port) async {
    if (_disposed || port == null || !state.canRun) return;
    await _run(port, port.run);
  }

  Future<void> retry(SyncRuntimePort? port) async {
    if (_disposed ||
        state.isBusy ||
        port == null ||
        port is! SyncRuntimeControls) {
      return;
    }
    await refresh(port);
    if (_disposed || !state.canRun) return;
    await _run(port, (port as SyncRuntimeControls).retry);
  }

  Future<void> importCloudMusic(SyncRuntimePort? port) async {
    if (_disposed ||
        state.isBusy ||
        port == null ||
        port is! RemoteMusicImportControls) {
      return;
    }
    await refresh(port);
    if (_disposed || !state.canRun) return;
    await _run(port, (port as RemoteMusicImportControls).importCloudMusic);
  }

  Future<void> _run(
    SyncRuntimePort port,
    Future<void> Function() operation,
  ) async {
    final request = ++_request;
    state = const SyncGateState(
      status: SyncGateStatus.busy,
      title: 'Sync in progress',
      message: '',
    );
    try {
      await operation();
      if (_disposed || request != _request) return;
      state = const SyncGateState(
        status: SyncGateStatus.ready,
        title: 'Sync complete',
        message: '',
      );
    } catch (_) {
      if (_disposed || request != _request) return;
      if (port is SyncRuntimeControls) {
        final snapshot = (port as SyncRuntimeControls).snapshot;
        if (snapshot.phase == ForegroundRunPhase.blocked ||
            snapshot.phase == ForegroundRunPhase.failed) {
          state = SyncGateState(
            status: snapshot.phase == ForegroundRunPhase.blocked
                ? SyncGateStatus.unavailable
                : SyncGateStatus.failed,
            title: snapshot.phase == ForegroundRunPhase.blocked
                ? 'Sync blocked'
                : 'Sync incomplete',
            message: snapshot.message,
          );
          return;
        }
      }
      state = const SyncGateState(
        status: SyncGateStatus.failed,
        title: 'Sync incomplete',
        message: 'Sync requirements or the connection changed. Scan again and retry.',
      );
    }
  }
}

final syncGateProvider = NotifierProvider<SyncGateViewModel, SyncGateState>(
  SyncGateViewModel.new,
);
