import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      title = '同步尚未开放',
      message = '平台授权、远端兼容性和同步服务完成验证后才能开始同步。';

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
  });

  const ForegroundRuntimeSnapshot.idle()
    : phase = ForegroundRunPhase.idle,
      message = '等待同步',
      runToken = null,
      lastStartedAtUtc = null;

  final ForegroundRunPhase phase;
  final String message;
  final String? runToken;
  final DateTime? lastStartedAtUtc;

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
) async* {
  yield runtime.snapshot;
  yield* runtime.snapshots;
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
    final request = ++_request;
    if (_disposed) return;
    if (port == null) {
      if (_disposed || request != _request) return;
      state = const SyncGateState.unavailable();
      return;
    }
    state = const SyncGateState(
      status: SyncGateStatus.busy,
      title: '正在检查同步条件',
      message: '正在确认本地授权、远端连接和安全条件。',
    );
    try {
      final next = await port.check();
      if (_disposed || request != _request) return;
      state = next;
    } catch (_) {
      if (_disposed || request != _request) return;
      state = const SyncGateState(
        status: SyncGateStatus.failed,
        title: '同步条件检查失败',
        message: '请检查连接和授权后重试。',
      );
    }
  }

  Future<void> run(SyncRuntimePort? port) async {
    if (_disposed || port == null || !state.canRun) return;
    final request = ++_request;
    state = const SyncGateState(
      status: SyncGateStatus.busy,
      title: '同步进行中',
      message: '正在执行同步，请稍候。',
    );
    try {
      await port.run();
      if (_disposed || request != _request) return;
      state = const SyncGateState(
        status: SyncGateStatus.ready,
        title: '同步已完成',
        message: '本地与远端内容已完成本次同步。',
      );
    } catch (_) {
      if (_disposed || request != _request) return;
      state = const SyncGateState(
        status: SyncGateStatus.failed,
        title: '同步未完成',
        message: '同步条件或连接发生变化，请重新扫描后重试。',
      );
    }
  }
}

final syncGateProvider = NotifierProvider<SyncGateViewModel, SyncGateState>(
  SyncGateViewModel.new,
);
