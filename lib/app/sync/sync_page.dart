import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/sync_components.dart';
import '../design/sync_theme.dart';
import '../localization/strings.dart';
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

    final isPartialScan =
        scan.status == MusicScanStatus.ready && !scan.complete;
    final isScanLoading = scan.status == MusicScanStatus.loading;
    final isScanFailed = scan.status == MusicScanStatus.failed;
    final isScanIdle = scan.status == MusicScanStatus.idle;

    // Scan only blocks if it is actively running, failed, or was an incomplete partial scan.
    final blockedByScan = isPartialScan || isScanFailed || isScanLoading;
    final canRun =
        grant != null &&
        rootStatus == 'ready' &&
        !blockedByScan &&
        gate.canRun &&
        !gate.isBusy &&
        !runtimeSnapshot.isRunning &&
        syncStatus != 'running';
    final canRetry =
        controls != null &&
        grant != null &&
        rootStatus == 'ready' &&
        !blockedByScan &&
        !gate.isBusy &&
        runtimeSnapshot.canRetry;

    // Automatically refresh music library when sync finishes.
    ref.listen(syncRuntimeSnapshotProvider, (previous, next) {
      final prevPhase = previous?.asData?.value.phase;
      final nextPhase = next.asData?.value.phase;
      if (nextPhase == ForegroundRunPhase.succeeded &&
          prevPhase != ForegroundRunPhase.succeeded) {
        if (grant != null) {
          ref.read(musicScanProvider.notifier).scan(grant);
        }
      }
    });

    final status = _statusCard(
      context,
      ref: ref,
      grant: grant,
      rootStatus: rootStatus,
      scan: scan,
      gate: gate,
      runtimeSnapshot: runtimeSnapshot,
      blockedByScan: blockedByScan,
      isPartialScan: isPartialScan,
      isScanIdle: isScanIdle,
      onRefreshGate: runtime == null || runtimeSnapshot.isRunning
          ? null
          : () => ref.read(syncGateProvider.notifier).refresh(runtime),
    );

    return SyncTunePageScaffold(
      title: 'Sync',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SyncTuneSection(title: 'Sync status', child: status),
          const SizedBox(height: SyncTuneTokens.space24),
          Wrap(
            spacing: SyncTuneTokens.space12,
            runSpacing: SyncTuneTokens.space8,
            children: [
              if (runtimeSnapshot.requiresRemoteImport &&
                  runtime is RemoteMusicImportControls)
                FilledButton.icon(
                  onPressed: canRetry
                      ? () => ref
                            .read(syncGateProvider.notifier)
                            .importCloudMusic(runtime)
                      : null,
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const LocalizedText('Import cloud music'),
                ),
              FilledButton.icon(
                onPressed:
                    runtimeSnapshot.phase == ForegroundRunPhase.cancelling
                    ? null
                    : runtimeSnapshot.isRunning && controls != null
                    ? controls.cancel
                    : canRetry
                    ? () {
                        if (isScanIdle) {
                          unawaited(
                            ref.read(musicScanProvider.notifier).scan(grant),
                          );
                        }
                        ref.read(syncGateProvider.notifier).retry(runtime);
                      }
                    : canRun
                    ? () {
                        if (isScanIdle) {
                          unawaited(
                            ref.read(musicScanProvider.notifier).scan(grant),
                          );
                        }
                        ref.read(syncGateProvider.notifier).run(runtime);
                      }
                    : null,
                icon: runtimeSnapshot.isRunning
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        runtimeSnapshot.canRetry ? Icons.replay : Icons.sync,
                      ),
                label: LocalizedText(
                  runtimeSnapshot.isRunning
                      ? runtimeSnapshot.phase == ForegroundRunPhase.cancelling
                            ? 'Canceling sync'
                            : 'Cancel sync'
                      : runtimeSnapshot.canRetry
                      ? 'Retry'
                      : gate.isBusy
                      ? 'Working…'
                      : 'Start sync',
                ),
              ),
              OutlinedButton.icon(
                onPressed:
                    runtime == null || runtimeSnapshot.isRunning || gate.isBusy
                    ? null
                    : () =>
                          ref.read(syncGateProvider.notifier).refresh(runtime),
                icon: const Icon(Icons.refresh),
                label: const LocalizedText('Check again'),
              ),
            ],
          ),
          if (syncStatus != 'idle') ...[
            const SizedBox(height: SyncTuneTokens.space12),
            LocalizedText(
              'Current task: ${SyncTuneStrings.of(context).text(syncStatus)}',
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusCard(
    BuildContext context, {
    required WidgetRef ref,
    required RootGrant? grant,
    required String rootStatus,
    required MusicScanState scan,
    required SyncGateState gate,
    required ForegroundRuntimeSnapshot runtimeSnapshot,
    required bool blockedByScan,
    required bool isPartialScan,
    required bool isScanIdle,
    required VoidCallback? onRefreshGate,
  }) {
    if (runtimeSnapshot.isRunning) {
      return _SyncRunDetails(snapshot: runtimeSnapshot);
    }
    if (grant == null && (rootStatus == 'error' || rootStatus == 'revoked')) {
      return const SyncTuneStatusCard(
        title: 'Folder access expired',
        message: 'Choose the folder again in Settings.',
        icon: Icons.folder_off_outlined,
        tone: SyncTuneStatusTone.error,
      );
    }
    if (grant == null || rootStatus == 'none') {
      return const SyncTuneStatusCard(
        title: 'Music root folder access required',
        message: 'Select a music folder in Settings.',
        icon: Icons.lock_outline,
      );
    }
    if (rootStatus == 'loading') {
      return const SyncTuneStatusCard(
        title: 'Checking folder access',
        icon: Icons.hourglass_top_outlined,
      );
    }
    if (scan.status == MusicScanStatus.loading) {
      return const SyncTuneStatusCard(
        title: 'Scan in progress',
        message: 'Finish the scan before syncing.',
        icon: Icons.sync_outlined,
        tone: SyncTuneStatusTone.warning,
      );
    }
    if (scan.status == MusicScanStatus.failed) {
      return SyncTuneStatusCard(
        title: 'Scan status unavailable',
        message: 'Rescan on Music to confirm folder access.',
        icon: Icons.error_outline,
        tone: SyncTuneStatusTone.error,
        action: OutlinedButton.icon(
          onPressed: () =>
              ref.read(musicScanProvider.notifier).scan(grant),
          icon: const Icon(Icons.search),
          label: const LocalizedText('Scan music'),
        ),
      );
    }
    if (isPartialScan) {
      return SyncTuneStatusCard(
        title: 'Incomplete scan',
        message: 'Partial scans cannot schedule deletions. Run a full scan.',
        icon: Icons.warning_amber,
        tone: SyncTuneStatusTone.warning,
        action: OutlinedButton.icon(
          onPressed: () =>
              ref.read(musicScanProvider.notifier).scan(grant),
          icon: const Icon(Icons.search),
          label: const LocalizedText('Scan music'),
        ),
      );
    }
    if (runtimeSnapshot.phase == ForegroundRunPhase.failed ||
        runtimeSnapshot.phase == ForegroundRunPhase.cancelled) {
      return SyncTuneStatusCard(
        title: runtimeSnapshot.phase == ForegroundRunPhase.cancelled
            ? 'Sync canceled'
            : 'Sync incomplete',
        message: [
          runtimeSnapshot.message,
          if (runtimeSnapshot.progress != null) runtimeSnapshot.progress!.stage,
          if (runtimeSnapshot.progress?.path != null)
            runtimeSnapshot.progress!.path!,
        ].join('\n'),
        icon: runtimeSnapshot.phase == ForegroundRunPhase.cancelled
            ? Icons.cancel_outlined
            : Icons.error_outline,
        tone: SyncTuneStatusTone.error,
      );
    }
    if (runtimeSnapshot.phase == ForegroundRunPhase.succeeded) {
      return SyncTuneStatusCard(
        title: 'Sync complete',
        icon: Icons.verified_outlined,
        tone: SyncTuneStatusTone.positive,
      );
    }
    if (gate.status == SyncGateStatus.unavailable) {
      const initial = SyncGateState.unavailable();
      final showRuntimeReason =
          runtimeSnapshot.phase == ForegroundRunPhase.blocked &&
          gate.title == initial.title &&
          gate.message == initial.message;
      return SyncTuneStatusCard(
        title: showRuntimeReason ? 'Sync blocked' : gate.title,
        message: showRuntimeReason ? runtimeSnapshot.message : gate.message,
        icon: Icons.lock_outline,
      );
    }
    if (isScanIdle && gate.canRun && !runtimeSnapshot.isRunning) {
      return SyncTuneStatusCard(
        title: 'Ready to sync',
        message:
            'Sync will scan local music automatically, or you can scan first.',
        icon: Icons.sync,
        action: OutlinedButton.icon(
          onPressed: () =>
              ref.read(musicScanProvider.notifier).scan(grant),
          icon: const Icon(Icons.search),
          label: const LocalizedText('Scan music'),
        ),
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
              label: const LocalizedText('Check sync requirements'),
            ),
    );
  }
}

class _SyncRunDetails extends StatefulWidget {
  const _SyncRunDetails({required this.snapshot});
  final ForegroundRuntimeSnapshot snapshot;

  @override
  State<_SyncRunDetails> createState() => _SyncRunDetailsState();
}

class _SyncRunDetailsState extends State<_SyncRunDetails> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  String _bytes(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  Widget _buildStepBadge(
    BuildContext context, {
    required String label,
    required bool isDone,
    required bool isActive,
  }) {
    final colors = Theme.of(context).colorScheme;
    final color = isDone
        ? colors.primary
        : isActive
            ? colors.tertiary
            : colors.outlineVariant;
    final textColor = isDone || isActive
        ? colors.onSurface
        : colors.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isDone
              ? Icons.check_circle
              : isActive
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 4),
        LocalizedText(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            color: textColor,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final progress = snapshot.progress;
    final start = snapshot.lastStartedAtUtc;
    final seconds = start == null
        ? 0
        : DateTime.now().toUtc().difference(start).inSeconds.clamp(0, 864000);
    final lastUpdate = snapshot.lastProgressAtUtc ?? start;
    final waiting =
        lastUpdate != null &&
        DateTime.now().toUtc().difference(lastUpdate) >=
            const Duration(seconds: 15);
    final totalBytes = progress?.totalBytes;
    final totalItems = progress?.totalItems;
    final ratio = totalBytes != null && totalBytes > 0
        ? (progress!.completedBytes / totalBytes).clamp(0.0, 1.0)
        : totalItems != null && totalItems > 0
        ? (progress!.completedItems / totalItems).clamp(0.0, 1.0)
        : null;

    final stage = progress?.stage ?? snapshot.message;
    final isVerifying = stage.contains('Verifying') ||
        stage.contains('Hashing') ||
        stage == 'Saving sync result';
    final isTransferring = stage == 'Downloading' ||
        stage == 'Uploading' ||
        stage == 'Deleting local file' ||
        stage == 'Deleting cloud file' ||
        stage == 'Preserving conflicting files' ||
        stage == 'Updating favorites' ||
        stage == 'File operations complete';

    final stepIndex = isVerifying
        ? 3
        : isTransferring
            ? 2
            : 1;

    return SyncTuneStatusCard(
      title: snapshot.phase == ForegroundRunPhase.cancelling
          ? 'Canceling sync'
          : snapshot.phase == ForegroundRunPhase.checking
          ? 'Checking sync requirements'
          : 'Sync in progress',
      message: snapshot.message,
      icon: Icons.sync,
      action: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildStepBadge(
                context,
                label: 'Scan',
                isDone: stepIndex > 1,
                isActive: stepIndex == 1,
              ),
              Icon(
                Icons.chevron_right,
                size: 14,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              _buildStepBadge(
                context,
                label: 'Transfer',
                isDone: stepIndex > 2,
                isActive: stepIndex == 2,
              ),
              Icon(
                Icons.chevron_right,
                size: 14,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              _buildStepBadge(
                context,
                label: 'Verify',
                isDone: false,
                isActive: stepIndex == 3,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (progress?.path != null) ...[
            Text(progress!.path!, key: const ValueKey('sync-current-file')),
            const SizedBox(height: 8),
          ],
          LinearProgressIndicator(value: ratio),
          const SizedBox(height: 8),
          if (totalItems != null || progress?.path != null)
            LocalizedText(
              '${progress!.itemLabel}: ${progress.completedItems}${totalItems == null ? '' : ' / $totalItems'}',
            ),
          if (totalBytes != null)
            LocalizedText(
              isVerifying
                  ? 'Verified data: ${_bytes(progress!.completedBytes)} / ${_bytes(totalBytes)}'
                  : 'File data processed: ${_bytes(progress!.completedBytes)} / ${_bytes(totalBytes)}',
            ),
          if (isVerifying)
            const Padding(
              padding: EdgeInsets.only(top: 2, bottom: 2),
              child: LocalizedText(
                'Checking file checksum (local integrity check, not re-downloading)',
                style: TextStyle(fontSize: 12),
              ),
            ),
          LocalizedText(
            'Elapsed: ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
          ),
          if (waiting)
            const LocalizedText(
              'Waiting for the current operation to respond…',
            ),
        ],
      ),
    );
  }
}
