import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/sync_components.dart';
import '../design/sync_theme.dart';
import '../music/music_scan.dart';
import 'sync_gate.dart';
import 'sync_status_view_model.dart';

class SyncPage extends ConsumerWidget {
  const SyncPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grant = ref.watch(rootGrantProvider);
    final rootStatus = ref.watch(rootAccessStatusProvider);
    final scan = ref.watch(musicScanProvider);
    final syncStatus = ref.watch(syncStatusProvider);
    final gate = ref.watch(syncGateProvider);
    final runtime = ref.watch(syncRuntimePortProvider);
    final controls = runtime is SyncRuntimeControls
        ? runtime as SyncRuntimeControls
        : null;
    final runtimeSnapshot =
        ref.watch(syncRuntimeSnapshotProvider).asData?.value ??
        controls?.snapshot ??
        const ForegroundRuntimeSnapshot.idle();

    final hasCompleteScan =
        scan.status == MusicScanStatus.ready && scan.complete;
    final blockedByScan =
        scan.status != MusicScanStatus.ready || !scan.complete;
    final canRun =
        grant != null &&
        rootStatus == 'ready' &&
        hasCompleteScan &&
        gate.canRun &&
        !gate.isBusy &&
        syncStatus != 'running';
    final canRetry =
        controls != null &&
        grant != null &&
        rootStatus == 'ready' &&
        hasCompleteScan &&
        runtimeSnapshot.canRetry;

    final status = _statusCard(
      context,
      grant: grant,
      rootStatus: rootStatus,
      scan: scan,
      gate: gate,
      runtimeSnapshot: runtimeSnapshot,
      blockedByScan: blockedByScan,
      onRefreshGate: runtime == null
          ? null
          : () => ref.read(syncGateProvider.notifier).refresh(runtime),
    );

    return SyncTunePageScaffold(
      title: '同步',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SyncTuneSection(
            title: '同步状态',
            description: '同步只会在目录扫描完整且所有安全条件通过后执行。',
            child: status,
          ),
          const SizedBox(height: SyncTuneTokens.space24),
          Wrap(
            spacing: SyncTuneTokens.space12,
            runSpacing: SyncTuneTokens.space8,
            children: [
              FilledButton.icon(
                onPressed: runtimeSnapshot.isRunning && controls != null
                    ? controls.cancel
                    : canRetry
                    ? controls.retry
                    : canRun
                    ? () => ref.read(syncGateProvider.notifier).run(runtime)
                    : null,
                icon: runtimeSnapshot.isRunning
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        runtimeSnapshot.canRetry ? Icons.replay : Icons.sync,
                      ),
                label: Text(
                  runtimeSnapshot.isRunning
                      ? '取消同步'
                      : runtimeSnapshot.canRetry
                      ? '重试'
                      : gate.isBusy
                      ? '处理中…'
                      : '开始同步',
                ),
              ),
              OutlinedButton.icon(
                onPressed: runtime == null
                    ? null
                    : () =>
                          ref.read(syncGateProvider.notifier).refresh(runtime),
                icon: const Icon(Icons.refresh),
                label: const Text('重新检查'),
              ),
            ],
          ),
          if (syncStatus != 'idle') ...[
            const SizedBox(height: SyncTuneTokens.space12),
            Text('当前任务：$syncStatus'),
          ],
        ],
      ),
    );
  }

  Widget _statusCard(
    BuildContext context, {
    required RootGrant? grant,
    required String rootStatus,
    required MusicScanState scan,
    required SyncGateState gate,
    required ForegroundRuntimeSnapshot runtimeSnapshot,
    required bool blockedByScan,
    required VoidCallback? onRefreshGate,
  }) {
    if (grant == null && (rootStatus == 'error' || rootStatus == 'revoked')) {
      return const SyncTuneStatusCard(
        title: '目录授权已失效',
        message: '请在设置中重新选择音乐根目录。',
        icon: Icons.folder_off_outlined,
        tone: SyncTuneStatusTone.error,
      );
    }
    if (grant == null || rootStatus == 'none') {
      return const SyncTuneStatusCard(
        title: '尚未授权音乐根目录',
        message: '选择并确认音乐根目录后，才能检查同步条件。',
        icon: Icons.lock_outline,
      );
    }
    if (rootStatus == 'loading') {
      return const SyncTuneStatusCard(
        title: '正在确认目录授权',
        message: '授权确认完成后才能继续。',
        icon: Icons.hourglass_top_outlined,
      );
    }
    if (scan.status == MusicScanStatus.loading) {
      return const SyncTuneStatusCard(
        title: '扫描进行中',
        message: '扫描完成后才能生成安全的同步计划。',
        icon: Icons.sync_outlined,
        tone: SyncTuneStatusTone.warning,
      );
    }
    if (scan.status == MusicScanStatus.failed) {
      return const SyncTuneStatusCard(
        title: '扫描状态不可用',
        message: '请在音乐页面重新扫描，确认目录完整可读。',
        icon: Icons.error_outline,
        tone: SyncTuneStatusTone.error,
      );
    }
    if (blockedByScan) {
      return SyncTuneStatusCard(
        title: scan.status == MusicScanStatus.ready && !scan.complete
            ? '扫描不完整'
            : '尚未完成扫描',
        message: scan.status == MusicScanStatus.ready && !scan.complete
            ? '部分扫描不能安排删除操作，请完成一次完整扫描。'
            : '请先在音乐页面完成扫描，再检查同步条件。',
        icon: Icons.warning_amber,
        tone: SyncTuneStatusTone.warning,
      );
    }
    if (runtimeSnapshot.phase == ForegroundRunPhase.failed ||
        runtimeSnapshot.phase == ForegroundRunPhase.cancelled) {
      return SyncTuneStatusCard(
        title: runtimeSnapshot.phase == ForegroundRunPhase.cancelled
            ? '同步已取消'
            : '同步未完成',
        message: runtimeSnapshot.message,
        icon: runtimeSnapshot.phase == ForegroundRunPhase.cancelled
            ? Icons.cancel_outlined
            : Icons.error_outline,
        tone: SyncTuneStatusTone.error,
      );
    }
    if (runtimeSnapshot.phase == ForegroundRunPhase.succeeded) {
      return SyncTuneStatusCard(
        title: '同步已完成',
        message: runtimeSnapshot.message,
        icon: Icons.verified_outlined,
        tone: SyncTuneStatusTone.positive,
      );
    }
    if (gate.status == SyncGateStatus.unavailable) {
      return const SyncTuneStatusCard(
        title: '同步尚未开放',
        message: '同步适配器和平台安全闸门尚未完成验收，当前不可执行。',
        icon: Icons.lock_outline,
      );
    }
    return SyncTuneStatusCard(
      title: gate.title,
      message: gate.message,
      icon: gate.canRun ? Icons.verified_outlined : Icons.sync_problem_outlined,
      tone: gate.canRun
          ? SyncTuneStatusTone.positive
          : gate.status == SyncGateStatus.failed
          ? SyncTuneStatusTone.error
          : SyncTuneStatusTone.warning,
      action: onRefreshGate == null
          ? null
          : OutlinedButton.icon(
              onPressed: onRefreshGate,
              icon: const Icon(Icons.refresh),
              label: const Text('检查同步条件'),
            ),
    );
  }
}
