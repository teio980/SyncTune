import 'dart:async';
import 'dart:math';

import 'package:synctune_sync_core/synctune_sync_core.dart';

import '../../app/sync/sync_gate.dart';

/// The identity captured by one foreground run. A changed root generation or
/// composition epoch makes the in-flight run stale before its result is used.
final class SyncRuntimeTarget {
  const SyncRuntimeTarget({
    required this.rootToken,
    required this.rootGeneration,
    required this.configEpoch,
    this.credentialEpoch = 'credential-initial',
  });

  final String rootToken;
  final String rootGeneration;
  final String configEpoch;

  /// Changes when credentials are replaced while the endpoint/catalog
  /// namespace remains stable. It participates in run identity so an old
  /// authenticated request is cancelled without forking the catalog.
  final String credentialEpoch;

  String get identity =>
      '$rootToken:$rootGeneration:$configEpoch:$credentialEpoch';
}

abstract interface class SyncRuntimeTargetPort {
  SyncRuntimeTarget? get current;

  Stream<SyncRuntimeTarget?> get changes;
}

/// Runner implemented by the composition root. Its run method must use the
/// provided CancellationToken in snapshot, IPC, transport and core executor
/// calls, and return the coordinator's complete result.
abstract interface class ConfirmedSyncRunner {
  Future<SyncGateState> check(
    SyncRuntimeTarget target, {
    CancellationToken token = const NeverCancelled(),
  });

  Future<SyncRunResult> run(
    SyncRuntimeTarget target, {
    required String runToken,
    CancellationToken token = const NeverCancelled(),
  });
}

abstract interface class RuntimeClock {
  DateTime get nowUtc;
}

final class SystemRuntimeClock implements RuntimeClock {
  const SystemRuntimeClock();

  @override
  DateTime get nowUtc => DateTime.now().toUtc();
}

/// Supplies durable identities for plan/run records. The default uses 128 bits
/// of cryptographic entropy per runtime session, while tests and a composition
/// root may inject a deterministic or persisted implementation.
abstract interface class RuntimeTokenGenerator {
  String newSessionId();

  String newRunToken(String sessionId, int sequence);
}

/// Alias kept for callers that prefer to describe the value as a runtime
/// identity rather than a token.
typedef RuntimeIdentityGenerator = RuntimeTokenGenerator;

final class SystemRuntimeTokenGenerator implements RuntimeTokenGenerator {
  const SystemRuntimeTokenGenerator();

  @override
  String newSessionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final entropy = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'session-$entropy';
  }

  @override
  String newRunToken(String sessionId, int sequence) =>
      '$sessionId-run-${sequence.toRadixString(36)}';
}

abstract interface class RuntimeTimerHandle {
  bool get isActive;

  void cancel();
}

abstract interface class RuntimeTimerFactory {
  RuntimeTimerHandle schedule(Duration delay, void Function() callback);
}

final class DartRuntimeTimerFactory implements RuntimeTimerFactory {
  const DartRuntimeTimerFactory();

  @override
  RuntimeTimerHandle schedule(Duration delay, void Function() callback) =>
      _DartRuntimeTimer(Timer(delay, callback));
}

final class _DartRuntimeTimer implements RuntimeTimerHandle {
  _DartRuntimeTimer(this._timer);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}

enum ForegroundLifecycleEvent { resumed, inactive, hidden, paused, detached }

abstract interface class ForegroundLifecyclePort {
  Stream<ForegroundLifecycleEvent> get events;
}

/// A cancellation source that can be passed directly to sync_core and
/// observed by platform/transport adapters at every I/O boundary.
final class RuntimeCancellationSource
    implements CancellationToken, CancellationSignal {
  final StreamController<void> _controller = StreamController<void>.broadcast();
  bool _cancelled = false;

  Stream<void> get cancelled => _controller.stream;

  @override
  Future<void>? get onCancel =>
      _cancelled ? Future<void>.value() : _controller.stream.first;

  @override
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_controller.isClosed) {
      _controller.add(null);
    }
  }

  @override
  void throwIfCancelled() {
    if (_cancelled) throw const SyncCancelled();
  }

  Future<void> dispose() async {
    if (_controller.isClosed) return;
    await _controller.close();
  }
}

final class SyncRuntimeNotReady implements Exception {
  const SyncRuntimeNotReady(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Foreground-only scheduler for startup, resume, manual and 15-minute work.
/// It never promises execution while the app is paused or closed.
final class ForegroundSyncRuntime
    implements SyncRuntimePort, SyncRuntimeControls {
  ForegroundSyncRuntime({
    required this.targetPort,
    required this.runner,
    RuntimeClock clock = const SystemRuntimeClock(),
    RuntimeTimerFactory timers = const DartRuntimeTimerFactory(),
    ForegroundLifecyclePort? lifecycle,
    RuntimeTokenGenerator? tokenGenerator,
    RuntimeIdentityGenerator? identityGenerator,
    this.interval = const Duration(minutes: 15),
  }) : _clock = clock, // ignore: prefer_initializing_formals
       _timers = timers, // ignore: prefer_initializing_formals
       _lifecycle = lifecycle, // ignore: prefer_initializing_formals
       _tokenGenerator =
           tokenGenerator ??
           identityGenerator ??
           const SystemRuntimeTokenGenerator(),
       _sessionId =
           (tokenGenerator ??
                   identityGenerator ??
                   const SystemRuntimeTokenGenerator())
               .newSessionId();

  final SyncRuntimeTargetPort targetPort;
  final ConfirmedSyncRunner runner;
  final RuntimeClock _clock;
  final RuntimeTimerFactory _timers;
  final ForegroundLifecyclePort? _lifecycle;
  final RuntimeTokenGenerator _tokenGenerator;
  final String _sessionId;
  final Duration interval;

  final StreamController<ForegroundRuntimeSnapshot> _updates =
      StreamController<ForegroundRuntimeSnapshot>.broadcast();
  ForegroundRuntimeSnapshot _snapshot = const ForegroundRuntimeSnapshot.idle();
  StreamSubscription<SyncRuntimeTarget?>? _targetSubscription;
  StreamSubscription<ForegroundLifecycleEvent>? _lifecycleSubscription;
  RuntimeTimerHandle? _timer;
  RuntimeCancellationSource? _source;
  final Set<RuntimeCancellationSource> _checks = <RuntimeCancellationSource>{};
  final Set<Future<SyncGateState>> _checksInFlight = <Future<SyncGateState>>{};
  Future<void>? _activeRun;
  bool _pending = false;
  Completer<void>? _pendingBatch;
  bool _foreground = true;
  bool _started = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  int _epoch = 0;
  int _sequence = 0;

  @override
  ForegroundRuntimeSnapshot get snapshot => _snapshot;

  @override
  Stream<ForegroundRuntimeSnapshot> get snapshots => _updates.stream;

  /// Begins foreground scheduling. The initial request only performs real
  /// I/O if the injected runner's compatibility check returns ready.
  void start() {
    if (_started || _disposed) return;
    _targetSubscription = targetPort.changes.listen(_onTargetChanged);
    _lifecycleSubscription = _lifecycle?.events.listen(_onLifecycle);
    _onTargetChanged(targetPort.current);
    // The initial target notification establishes the epoch; the explicit
    // startup request below is the single first run rather than a coalesced
    // second request.
    _started = true;
    _pending = false;
    unawaited(_safeRequest('启动'));
  }

  @override
  Future<SyncGateState> check() {
    late Future<SyncGateState> operation;
    operation = _performCheck();
    late Future<SyncGateState> tracked;
    tracked = operation.whenComplete(() => _checksInFlight.remove(tracked));
    _checksInFlight.add(tracked);
    return tracked;
  }

  Future<SyncGateState> _performCheck() async {
    if (_disposed) return const SyncGateState.unavailable();
    final target = targetPort.current;
    if (target == null) {
      _publish(
        const ForegroundRuntimeSnapshot(
          phase: ForegroundRunPhase.blocked,
          message: '尚未授权同步根目录',
        ),
      );
      return const SyncGateState.unavailable();
    }
    final epoch = _epoch;
    final source = RuntimeCancellationSource();
    _checks.add(source);
    try {
      final gate = await runner.check(target, token: source);
      if (_disposed || epoch != _epoch || !_sameTarget(target)) {
        return const SyncGateState.unavailable();
      }
      return gate;
    } catch (_) {
      if (_disposed || epoch != _epoch) {
        return const SyncGateState.unavailable();
      }
      return const SyncGateState(
        status: SyncGateStatus.failed,
        title: '同步条件检查失败',
        message: '请检查连接和授权后重试。',
      );
    } finally {
      _checks.remove(source);
      await source.dispose();
    }
  }

  @override
  Future<void> run() {
    if (_disposed || !_foreground) return _cancelledRequest();
    return _request('手动');
  }

  @override
  Future<void> requestManual() {
    if (_disposed || !_foreground) return _cancelledRequest();
    return _request('手动');
  }

  @override
  Future<void> retry() {
    if (_disposed || !_foreground) return _cancelledRequest();
    return _request('重试');
  }

  Future<void> _cancelledRequest() => Future<void>.error(const SyncCancelled());

  @override
  Future<void> cancel() async {
    if (_disposed) return;
    _pending = false;
    _completePending(const SyncCancelled());
    _epoch++;
    _timer?.cancel();
    _timer = null;
    final source = _source;
    if (source == null) {
      _publish(
        const ForegroundRuntimeSnapshot(
          phase: ForegroundRunPhase.cancelled,
          message: '同步已取消',
        ),
      );
      return;
    }
    _publish(
      ForegroundRuntimeSnapshot(
        phase: ForegroundRunPhase.cancelling,
        message: '正在取消同步',
        runToken: _snapshot.runToken,
        lastStartedAtUtc: _snapshot.lastStartedAtUtc,
      ),
    );
    source.cancel();
    try {
      await _activeRun;
    } catch (_) {
      // Cancellation is an expected foreground lifecycle outcome.
    }
  }

  void onResume() {
    if (_disposed) return;
    _foreground = true;
    _schedule();
    unawaited(_safeRequest('恢复'));
  }

  void onPause() {
    if (_disposed) return;
    _foreground = false;
    _timer?.cancel();
    _timer = null;
    if (_source != null) unawaited(cancel());
    if (_activeRun == null) {
      _publish(
        const ForegroundRuntimeSnapshot(
          phase: ForegroundRunPhase.idle,
          message: '应用已挂起，等待恢复后同步',
        ),
      );
    }
  }

  void dispose() {
    unawaited(disposeAndWait());
  }

  /// Cancels in-flight checks/runs and waits for their finally blocks. The
  /// composition root uses this before closing Drift so no late coordinator
  /// write can touch a closed database.
  Future<void> disposeAndWait() => _disposeFuture ??= _disposeAndWait();

  Future<void> _disposeAndWait() async {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _pending = false;
    _completePending(const SyncCancelled());
    _timer?.cancel();
    _timer = null;
    _targetSubscription?.cancel();
    _lifecycleSubscription?.cancel();
    _source?.cancel();
    for (final check in _checks) {
      check.cancel();
    }
    final active = _activeRun;
    if (active != null) {
      try {
        await active;
      } catch (_) {
        // Cancellation is the expected result while disposing.
      }
    }
    for (final check in _checksInFlight.toList()) {
      try {
        await check;
      } catch (_) {
        // Cancellation and a stale target are expected while disposing.
      }
    }
    await _source?.dispose();
    if (!_updates.isClosed) await _updates.close();
  }

  Future<void> _request(String reason) {
    if (_disposed || !_foreground) return _cancelledRequest();
    if (_activeRun != null) {
      _pending = true;
      final completer = _pendingBatch ??= Completer<void>();
      return completer.future;
    }
    return _beginRun(reason);
  }

  Future<void> _beginRun(String reason) {
    _timer?.cancel();
    _timer = null;
    final run = _startRun(reason);
    _activeRun = run;
    // Complete the active slot even when the run failed. The callback also
    // owns coalescing and timer scheduling, so a stale future cannot block
    // future foreground requests forever.
    unawaited(
      run.then<void>(
        (_) => _finishActiveRun(run),
        onError: (Object error, StackTrace stack) => _finishActiveRun(run),
      ),
    );
    return run;
  }

  Future<void> _safeRequest(String reason) async {
    try {
      await _request(reason);
    } catch (_) {
      // The failed/cancelled snapshot is the user-facing result. Internal
      // lifecycle callbacks must not create an unhandled Future error.
    }
  }

  void _finishActiveRun(Future<void> run) {
    if (!identical(_activeRun, run)) return;
    _activeRun = null;
    _schedule();
    if (_pending && !_disposed && _foreground) {
      _pending = false;
      final pending = _pendingBatch;
      _pendingBatch = null;
      final next = _beginRun('合并请求');
      if (pending == null) {
        unawaited(_safeAwait(next));
      } else {
        next.then<void>(
          (_) {
            if (!pending.isCompleted) pending.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!pending.isCompleted) pending.completeError(error, stack);
          },
        );
      }
    } else if (_pendingBatch != null) {
      _completePending(const SyncCancelled());
      _pending = false;
    }
  }

  Future<void> _safeAwait(Future<void> future) async {
    try {
      await future;
    } catch (_) {
      // A lifecycle-triggered coalesced run has no external awaiter.
    }
  }

  void _completePending(Object error, [StackTrace? stack]) {
    final pending = _pendingBatch;
    _pendingBatch = null;
    if (pending == null || pending.isCompleted) return;
    pending.completeError(error, stack ?? StackTrace.current);
  }

  Future<void> _startRun(String reason) async {
    final target = targetPort.current;
    if (target == null) {
      _publish(
        const ForegroundRuntimeSnapshot(
          phase: ForegroundRunPhase.blocked,
          message: '尚未授权同步根目录',
        ),
      );
      throw const SyncRuntimeNotReady('尚未授权同步根目录');
    }
    final epoch = _epoch;
    final runToken = _tokenGenerator.newRunToken(_sessionId, ++_sequence);
    final source = RuntimeCancellationSource();
    _source = source;
    _publish(
      ForegroundRuntimeSnapshot(
        phase: ForegroundRunPhase.checking,
        message: '正在检查同步条件',
        runToken: runToken,
        lastStartedAtUtc: _clock.nowUtc,
      ),
    );
    try {
      final gate = await runner.check(target, token: source);
      _ensureCurrent(epoch, target, source);
      if (!gate.canRun) {
        _publish(
          ForegroundRuntimeSnapshot(
            phase: ForegroundRunPhase.blocked,
            message: gate.message,
            runToken: runToken,
            lastStartedAtUtc: _clock.nowUtc,
          ),
        );
        throw SyncRuntimeNotReady(gate.message);
      }
      _publish(
        ForegroundRuntimeSnapshot(
          phase: ForegroundRunPhase.running,
          message: '正在同步',
          runToken: runToken,
          lastStartedAtUtc: _clock.nowUtc,
        ),
      );
      final result = await runner.run(
        target,
        runToken: runToken,
        token: source,
      );
      _ensureCurrent(epoch, target, source);
      result.requireConfirmed();
      _publish(
        ForegroundRuntimeSnapshot(
          phase: ForegroundRunPhase.succeeded,
          message: '同步已完成',
          runToken: runToken,
          lastStartedAtUtc: _clock.nowUtc,
        ),
      );
    } catch (error) {
      if (_disposed) {
        throw const SyncCancelled();
      }
      if (error is SyncCancelled || source.isCancelled) {
        _publish(
          ForegroundRuntimeSnapshot(
            phase: ForegroundRunPhase.cancelled,
            message: '同步已取消',
            runToken: runToken,
            lastStartedAtUtc: _clock.nowUtc,
          ),
        );
        if (error is SyncCancelled) {
          rethrow;
        }
        throw const SyncCancelled();
      } else if (error is SyncRuntimeNotReady) {
        // The blocked snapshot already carries the gate's readable reason.
        // Preserve that state while allowing an awaited manual call to let
        // its gate view model handle the failed request.
        rethrow;
      } else {
        _publish(
          ForegroundRuntimeSnapshot(
            phase: ForegroundRunPhase.failed,
            message: '同步未完成，请检查连接后重试。',
            runToken: runToken,
            lastStartedAtUtc: _clock.nowUtc,
          ),
        );
        rethrow;
      }
    } finally {
      if (identical(_source, source)) _source = null;
      await source.dispose();
    }
  }

  void _ensureCurrent(
    int epoch,
    SyncRuntimeTarget target,
    RuntimeCancellationSource source,
  ) {
    if (_disposed ||
        epoch != _epoch ||
        source.isCancelled ||
        !_sameTarget(target)) {
      throw const SyncCancelled();
    }
  }

  bool _sameTarget(SyncRuntimeTarget target) =>
      targetPort.current?.identity == target.identity;

  void _onTargetChanged(SyncRuntimeTarget? target) {
    if (_disposed) return;
    _epoch++;
    if (_source != null) {
      _source!.cancel();
      _publish(
        const ForegroundRuntimeSnapshot(
          phase: ForegroundRunPhase.cancelling,
          message: '目录或连接设置已变化，正在取消旧同步',
        ),
      );
    }
    for (final check in _checks) {
      check.cancel();
    }
    if (target == null) {
      _completePending(const SyncCancelled());
      _pending = false;
      _publish(
        const ForegroundRuntimeSnapshot(
          phase: ForegroundRunPhase.blocked,
          message: '尚未授权同步根目录',
        ),
      );
    } else if (_foreground && _started) {
      if (_activeRun == null) {
        final request = _request('目录或连接设置已变化');
        unawaited(_safeAwait(request));
      } else {
        _pending = true;
      }
    }
  }

  void _onLifecycle(ForegroundLifecycleEvent event) {
    switch (event) {
      case ForegroundLifecycleEvent.resumed:
        onResume();
        break;
      case ForegroundLifecycleEvent.inactive:
        // Inactive is a visible, focus-lost state on Flutter desktop/mobile;
        // keep foreground work alive until hidden/paused/detached.
        break;
      case ForegroundLifecycleEvent.hidden:
      case ForegroundLifecycleEvent.paused:
      case ForegroundLifecycleEvent.detached:
        onPause();
        break;
    }
  }

  void _schedule() {
    if (_disposed ||
        !_foreground ||
        _activeRun != null ||
        targetPort.current == null) {
      return;
    }
    _timer?.cancel();
    _timer = _timers.schedule(interval, () {
      _timer = null;
      unawaited(_safeRequest('定时'));
    });
    if (_snapshot.phase == ForegroundRunPhase.idle ||
        _snapshot.phase == ForegroundRunPhase.scheduled) {
      _publish(
        ForegroundRuntimeSnapshot(
          phase: ForegroundRunPhase.scheduled,
          message: '前台等待下一次同步',
          runToken: _snapshot.runToken,
          lastStartedAtUtc: _snapshot.lastStartedAtUtc,
        ),
      );
    }
  }

  void _publish(ForegroundRuntimeSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    if (!_updates.isClosed) _updates.add(next);
  }
}
