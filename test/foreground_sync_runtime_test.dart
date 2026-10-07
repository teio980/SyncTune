import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import 'package:synctune/app/sync/sync_gate.dart';
import 'package:synctune/infrastructure/runtime/foreground_sync_runtime.dart';

void main() {
  test(
    'starts once and schedules the next run after fifteen minutes',
    () async {
      final target = FakeTargetPort(
        const SyncRuntimeTarget(
          rootToken: 'root',
          rootGeneration: 'g1',
          configEpoch: 'c1',
        ),
      );
      final timers = FakeTimerFactory();
      final runner = FakeRunner();
      final runtime = ForegroundSyncRuntime(
        targetPort: target,
        runner: runner,
        timers: timers,
      );

      runtime.start();
      await pumpRuntime();
      expect(runner.runs, 1);
      expect(timers.activeCount, 1);
      expect(timers.delays.single, const Duration(minutes: 15));

      timers.fireNext();
      await pumpRuntime();
      expect(runner.runs, 2);
      expect(timers.activeCount, 1);
      runtime.dispose();
    },
  );

  test('resume triggers a foreground run and pause cancels work', () async {
    final target = FakeTargetPort(_target('g1'));
    final runner = FakeRunner();
    final runtime = ForegroundSyncRuntime(targetPort: target, runner: runner);

    runtime.start();
    await pumpRuntime();
    expect(runner.runs, 1);
    runtime.onPause();
    await pumpRuntime();
    runtime.onResume();
    await pumpRuntime();
    expect(runner.runs, 2);
    runtime.dispose();
  });

  test('injected lifecycle events drive pause and resume scheduling', () async {
    final lifecycle = FakeLifecyclePort();
    final target = FakeTargetPort(_target('g1'));
    final runner = FakeRunner();
    final runtime = ForegroundSyncRuntime(
      targetPort: target,
      runner: runner,
      lifecycle: lifecycle,
    );

    runtime.start();
    await pumpRuntime();
    lifecycle.emit(ForegroundLifecycleEvent.paused);
    await pumpRuntime();
    lifecycle.emit(ForegroundLifecycleEvent.resumed);
    await pumpRuntime();
    expect(runner.runs, 2);
    runtime.dispose();
  });

  test('manual requests coalesce into one fresh run', () async {
    final target = FakeTargetPort(_target('g1'));
    final runner = FakeRunner();
    final runtime = ForegroundSyncRuntime(targetPort: target, runner: runner);

    runtime.start();
    await pumpRuntime();
    final second = Completer<SyncRunResult>();
    runner.runResults.add(second);
    final firstManual = runtime.requestManual();
    final secondManual = runtime.requestManual();
    await pumpRuntime();
    expect(runner.runs, 2);
    expect(firstManual, isNot(same(secondManual)));

    second.complete(successfulResult);
    await firstManual;
    await secondManual;
    await pumpRuntime();
    expect(runner.runs, 3);
    expect(runner.tokens.toSet(), hasLength(3));
    runtime.dispose();
  });

  test(
    'cancel propagates to the runner and retry starts a new token',
    () async {
      final target = FakeTargetPort(_target('g1'));
      final runner = FakeRunner();
      final runtime = ForegroundSyncRuntime(targetPort: target, runner: runner);

      runtime.start();
      await pumpRuntime();
      final pending = Completer<SyncRunResult>();
      runner.runResults.add(pending);
      final run = runtime.requestManual();
      await pumpRuntime();
      final token = runner.cancellationTokens.last;
      final cancelling = runtime.cancel();
      expect(token.isCancelled, isTrue);
      pending.complete(successfulResult);
      await cancelling;
      await expectLater(run, throwsA(isA<SyncCancelled>()));
      expect(runtime.snapshot.phase, ForegroundRunPhase.cancelled);

      await runtime.retry();
      await pumpRuntime();
      expect(runner.runs, 3);
      expect(runner.tokens.toSet(), hasLength(3));
      runtime.dispose();
    },
  );

  test(
    'changing the root cancels the old run and never writes its result',
    () async {
      final target = FakeTargetPort(_target('g1'));
      final runner = FakeRunner();
      final runtime = ForegroundSyncRuntime(targetPort: target, runner: runner);

      runtime.start();
      await pumpRuntime();
      final oldRun = Completer<SyncRunResult>();
      runner.runResults.add(oldRun);
      final oldRequest = runtime.requestManual();
      final oldOutcome = expectLater(oldRequest, throwsA(isA<SyncCancelled>()));
      await pumpRuntime();
      final oldToken = runner.cancellationTokens.last;
      target.setTarget(_target('g2'));
      await pumpRuntime();
      expect(oldToken.isCancelled, isTrue);
      oldRun.complete(successfulResult);
      await oldOutcome;
      await pumpRuntime();
      expect(runner.runs, 3);
      expect(runner.targets.last.rootGeneration, 'g2');
      expect(runtime.snapshot.runToken, lastToken(runner.tokens));
      runtime.dispose();
    },
  );

  test(
    'blocked compatibility gate never starts I/O and dispose is quiet',
    () async {
      final target = FakeTargetPort(_target('g1'));
      final runner = FakeRunner(
        gate: const SyncGateState(
          status: SyncGateStatus.unavailable,
          title: '不可用',
          message: '平台闸门未通过',
        ),
      );
      final runtime = ForegroundSyncRuntime(targetPort: target, runner: runner);

      runtime.start();
      await pumpRuntime();
      expect(runner.checks, 1);
      expect(runner.runs, 0);
      expect(runtime.snapshot.phase, ForegroundRunPhase.blocked);
      runtime.dispose();
      runtime.dispose();
      await pumpRuntime();
    },
  );

  test('an idle runtime starts a fresh run when the target changes', () async {
    final target = FakeTargetPort(_target('g1'));
    final runner = FakeRunner();
    final runtime = ForegroundSyncRuntime(targetPort: target, runner: runner);

    runtime.start();
    await pumpRuntime();
    target.setTarget(_target('g2'));
    await pumpRuntime();
    expect(runner.runs, 2);
    expect(runner.targets.last.rootGeneration, 'g2');
    runtime.dispose();
  });
}

Future<void> pumpRuntime() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.value();
  }
}

SyncRuntimeTarget _target(String generation) => SyncRuntimeTarget(
  rootToken: 'root',
  rootGeneration: generation,
  configEpoch: 'c1',
);

final successfulResult = SyncRunResult(
  plan: const SyncPlan(
    planId: 'runtime-test',
    generation: 'g1',
    operations: <SyncOperation>[],
    deletionsSuppressed: false,
  ),
  report: const ExecutionReport(
    completed: <String>[],
    skipped: <String>[],
    failed: <String, Object>{},
  ),
  baselineConfirmed: true,
);

final class FakeTargetPort implements SyncRuntimeTargetPort {
  FakeTargetPort(this.current);

  @override
  SyncRuntimeTarget? current;
  final StreamController<SyncRuntimeTarget?> _changes =
      StreamController<SyncRuntimeTarget?>.broadcast();

  @override
  Stream<SyncRuntimeTarget?> get changes => _changes.stream;

  void setTarget(SyncRuntimeTarget? value) {
    current = value;
    _changes.add(value);
  }
}

final class FakeLifecyclePort implements ForegroundLifecyclePort {
  final StreamController<ForegroundLifecycleEvent> _events =
      StreamController<ForegroundLifecycleEvent>.broadcast();

  @override
  Stream<ForegroundLifecycleEvent> get events => _events.stream;

  void emit(ForegroundLifecycleEvent event) => _events.add(event);
}

final class FakeRunner implements ConfirmedSyncRunner {
  FakeRunner({
    this.gate = const SyncGateState(
      status: SyncGateStatus.ready,
      title: '可用',
      message: 'ready',
    ),
  });

  final SyncGateState gate;
  final List<Completer<SyncRunResult>> runResults =
      <Completer<SyncRunResult>>[];
  final List<String> tokens = <String>[];
  final List<CancellationToken> cancellationTokens = <CancellationToken>[];
  final List<SyncRuntimeTarget> targets = <SyncRuntimeTarget>[];
  int checks = 0;
  int runs = 0;
  SyncRuntimeTarget? lastTarget;

  @override
  Future<SyncGateState> check(
    SyncRuntimeTarget target, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    checks++;
    token.throwIfCancelled();
    return gate;
  }

  @override
  Future<SyncRunResult> run(
    SyncRuntimeTarget target, {
    required String runToken,
    CancellationToken token = const NeverCancelled(),
  }) async {
    runs++;
    lastTarget = target;
    targets.add(target);
    tokens.add(runToken);
    cancellationTokens.add(token);
    if (runResults.isEmpty) {
      token.throwIfCancelled();
      return successfulResult;
    }
    final result = await runResults.removeAt(0).future;
    token.throwIfCancelled();
    return result;
  }
}

String? lastToken(List<String> values) =>
    values.isEmpty ? null : values[values.length - 1];

final class FakeTimerFactory implements RuntimeTimerFactory {
  final List<FakeTimerHandle> handles = <FakeTimerHandle>[];
  final List<Duration> delays = <Duration>[];

  int get activeCount => handles.where((handle) => handle.isActive).length;

  @override
  RuntimeTimerHandle schedule(Duration delay, void Function() callback) {
    delays.add(delay);
    final handle = FakeTimerHandle(callback);
    handles.add(handle);
    return handle;
  }

  void fireNext() {
    final handle = handles.firstWhere((candidate) => candidate.isActive);
    handle.fire();
  }
}

final class FakeTimerHandle implements RuntimeTimerHandle {
  FakeTimerHandle(this.callback);

  final void Function() callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }
}
