import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/sync_components.dart';
import '../design/sync_theme.dart';
import '../localization/strings.dart';
import '../sync/sync_gate.dart';
import '../sync/sync_status_view_model.dart';
import 'music_deletion.dart';
import 'music_scan.dart';

class MusicPage extends ConsumerWidget {
  const MusicPage({super.key, this.expandedLayout});

  final bool? expandedLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grant = ref.watch(rootGrantProvider);
    final rootStatus = ref.watch(rootAccessStatusProvider);
    final scan = ref.watch(musicScanProvider);
    final favorites = ref.watch(musicFavoritesProvider);
    final favoritesPort = ref.watch(musicFavoritesPortProvider);
    final favoriteMessage = ref.watch(musicFavoritesMessageProvider);
    final deletionState = ref.watch(musicDeletionProvider);
    final deletionPort = ref.watch(musicDeletionPortProvider);
    final runtimeSnapshot =
        ref.watch(syncRuntimeSnapshotProvider).asData?.value ??
            const ForegroundRuntimeSnapshot.idle();

    ref.listen(musicScanProvider, (previous, next) {
      if (next.status == MusicScanStatus.ready &&
          previous?.status != MusicScanStatus.ready) {
        if (grant != null) {
          ref.read(musicFavoritesProvider.notifier).load(grant);
        }
      }
    });

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

    final expanded = expandedLayout ?? MediaQuery.sizeOf(context).width >= 1000;
    return CustomScrollView(
      key: const PageStorageKey<String>('music-scroll'),
      slivers: [
        const SliverAppBar(title: LocalizedText('Music'), floating: true),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            SyncTuneTokens.space24,
            SyncTuneTokens.space16,
            SyncTuneTokens.space24,
            SyncTuneTokens.space16,
          ),
          sliver: SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: SyncTuneTokens.contentMaxWidth,
                ),
                child: _MusicOverview(
                  grant: grant,
                  rootStatus: rootStatus,
                  scan: scan,
                  favoriteMessage: favoriteMessage,
                  deletionState: deletionState,
                  onScan: grant == null || scan.isLoading
                      ? null
                      : () => ref.read(musicScanProvider.notifier).scan(grant),
                ),
              ),
            ),
          ),
        ),
        if (scan.status == MusicScanStatus.ready && scan.tracks.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              SyncTuneTokens.space24,
              0,
              SyncTuneTokens.space24,
              SyncTuneTokens.space32,
            ),
            sliver: SliverList.builder(
              itemCount: scan.tracks.length + (expanded ? 1 : 0),
              itemBuilder: (context, index) {
                if (expanded && index == 0) return const _TrackHeader();
                final track = scan.tracks[expanded ? index - 1 : index];
                final canDelete = grant != null &&
                    deletionPort != null &&
                    !runtimeSnapshot.isRunning &&
                    !deletionState.isDeleting;
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: SyncTuneTokens.contentMaxWidth,
                    ),
                    child: _TrackRow(
                      track: track,
                      expanded: expanded,
                      favorite: favorites.contains(
                        track.id ?? track.relativePath,
                      ),
                      onFavorite: favoritesPort == null
                          ? null
                          : () => ref
                                .read(musicFavoritesProvider.notifier)
                                .toggleTrack(track, grant: grant!),
                      canDelete: canDelete,
                      isDeleting: deletionState.isDeleting &&
                          deletionState.deletingPath == track.relativePath,
                      onDelete: canDelete
                          ? () => ref
                                .read(musicDeletionProvider.notifier)
                                .confirmAndDelete(context, track, grant: grant)
                          : null,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _MusicOverview extends StatelessWidget {
  const _MusicOverview({
    required this.grant,
    required this.rootStatus,
    required this.scan,
    required this.favoriteMessage,
    required this.deletionState,
    required this.onScan,
  });

  final RootGrant? grant;
  final String rootStatus;
  final MusicScanState scan;
  final String? favoriteMessage;
  final MusicDeletionState deletionState;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    final scanButton = FilledButton.icon(
      onPressed: onScan,
      icon: scan.isLoading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.search),
      label: LocalizedText(scan.isLoading ? 'Scanning…' : 'Scan music'),
    );

    final Widget status;
    if (grant == null && (rootStatus == 'error' || rootStatus == 'revoked')) {
      status = const SyncTuneStatusCard(
        title: 'Music root folder unavailable',
        message: 'Choose the folder again.',
        icon: Icons.folder_off_outlined,
        tone: SyncTuneStatusTone.error,
      );
    } else if (grant == null || rootStatus == 'none') {
      status = const SyncTuneStatusCard(
        title: 'No music root folder selected',
        message: 'Choose one in Settings.',
        icon: Icons.folder_outlined,
      );
    } else if (rootStatus == 'loading') {
      status = const SyncTuneStatusCard(
        title: 'Checking folder access',
        icon: Icons.hourglass_top_outlined,
      );
    } else if (scan.status == MusicScanStatus.loading) {
      status = const SyncTuneStatusCard(
        title: 'Scanning music',
        icon: Icons.sync_outlined,
        tone: SyncTuneStatusTone.warning,
      );
    } else if (scan.status == MusicScanStatus.failed) {
      status = SyncTuneStatusCard(
        title: 'Scan incomplete',
        message: 'Folder access changed. Reauthorize and retry.',
        icon: Icons.error_outline,
        tone: SyncTuneStatusTone.error,
        action: scanButton,
      );
    } else if (scan.status == MusicScanStatus.ready && scan.tracks.isEmpty) {
      status = SyncTuneStatusCard(
        title: scan.complete ? 'No music files found' : 'Incomplete scan',
        message: scan.complete
            ? 'Formats: mp3, flac, wav, m4a, aac, ogg, opus.'
            : 'Partial scans cannot schedule deletions. Run a full scan.',
        icon: scan.complete ? Icons.music_off_outlined : Icons.warning_amber,
        tone: scan.complete
            ? SyncTuneStatusTone.neutral
            : SyncTuneStatusTone.warning,
        action: scanButton,
      );
    } else if (scan.status == MusicScanStatus.ready && !scan.complete) {
      status = SyncTuneStatusCard(
        title: 'Incomplete scan',
        message: 'Partial scans cannot schedule deletions. Run a full scan.',
        icon: Icons.warning_amber,
        tone: SyncTuneStatusTone.warning,
        action: scanButton,
      );
    } else {
      status = SyncTuneStatusCard(
        title: 'Ready to scan music',
        message: 'Formats: mp3, flac, wav, m4a, aac, ogg, opus.',
        icon: Icons.folder_shared_outlined,
        tone: SyncTuneStatusTone.positive,
        action: scanButton,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (grant != null) ...[
          LocalizedText(
            '${SyncTuneStrings.of(context).text('Folder')}: ${grant!.path}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SyncTuneTokens.space16),
        ],
        status,
        if (deletionState.statusMessage != null) ...[
          const SizedBox(height: SyncTuneTokens.space12),
          SyncTuneStatusCard(
            title: 'Delete song',
            message: deletionState.statusMessage!,
            icon: Icons.sync_problem_outlined,
            tone: SyncTuneStatusTone.warning,
          ),
        ],
        if (deletionState.errorMessage != null) ...[
          const SizedBox(height: SyncTuneTokens.space12),
          SyncTuneStatusCard(
            title: 'Song deletion failed',
            message: deletionState.errorMessage!,
            icon: Icons.error_outline,
            tone: SyncTuneStatusTone.error,
          ),
        ],
        if (favoriteMessage != null) ...[
          const SizedBox(height: SyncTuneTokens.space12),
          SyncTuneStatusCard(
            title: 'Favorites status',
            message: favoriteMessage!,
            icon: Icons.error_outline,
            tone: SyncTuneStatusTone.error,
          ),
        ],
      ],
    );
  }
}

class _TrackHeader extends StatelessWidget {
  const _TrackHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SyncTuneTokens.space8),
      child: Row(
        children: [
          const SizedBox(width: 48),
          Expanded(
            child: LocalizedText(
              'File',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          const SizedBox(width: 100, child: LocalizedText('Format')),
          const SizedBox(width: 100, child: LocalizedText('Size')),
          const SizedBox(width: 64, child: LocalizedText('Favorite')),
          const SizedBox(width: 64, child: LocalizedText('Delete')),
        ],
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.track,
    required this.expanded,
    required this.favorite,
    required this.onFavorite,
    required this.canDelete,
    required this.isDeleting,
    required this.onDelete,
  });

  final MusicTrack track;
  final bool expanded;
  final bool favorite;
  final VoidCallback? onFavorite;
  final bool canDelete;
  final bool isDeleting;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final star = IconButton(
      tooltip: SyncTuneStrings.of(context).text(
        onFavorite == null
            ? 'Favorites service disconnected'
            : favorite
            ? 'Remove from favorites'
            : 'Favorite',
      ),
      onPressed: onFavorite,
      icon: Icon(favorite ? Icons.star : Icons.star_border),
    );
    final deleteButton = IconButton(
      tooltip: SyncTuneStrings.of(context).text(
        canDelete ? 'Delete song' : 'Delete unavailable',
      ),
      onPressed: canDelete ? onDelete : null,
      icon: isDeleting
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.delete_outline),
    );
    if (!expanded) {
      return Card(
        margin: const EdgeInsets.only(bottom: SyncTuneTokens.space8),
        child: ListTile(
          minVerticalPadding: SyncTuneTokens.space8,
          leading: const Icon(Icons.audio_file_outlined),
          title: Text(track.relativePath),
          subtitle: Text(
            '${track.extension.toUpperCase()} · ${formatBytes(track.size)}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              star,
              deleteButton,
            ],
          ),
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(
        minHeight: SyncTuneTokens.minInteractiveSize,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 48, child: Icon(Icons.audio_file_outlined)),
          Expanded(
            child: Text(track.relativePath, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(width: 100, child: Text(track.extension.toUpperCase())),
          SizedBox(width: 100, child: Text(formatBytes(track.size))),
          SizedBox(
            width: 64,
            child: Align(alignment: Alignment.centerLeft, child: star),
          ),
          SizedBox(
            width: 64,
            child: Align(alignment: Alignment.centerLeft, child: deleteButton),
          ),
        ],
      ),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
