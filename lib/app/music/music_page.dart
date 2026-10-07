import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/sync_components.dart';
import '../design/sync_theme.dart';
import '../sync/sync_status_view_model.dart';
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
    ref.listen(musicScanProvider, (previous, next) {
      if (next.status == MusicScanStatus.ready &&
          previous?.status != MusicScanStatus.ready) {
        if (grant != null) {
          ref.read(musicFavoritesProvider.notifier).load(grant);
        }
      }
    });

    final expanded = expandedLayout ?? MediaQuery.sizeOf(context).width >= 1000;
    return CustomScrollView(
      key: const PageStorageKey<String>('music-scroll'),
      slivers: [
        const SliverAppBar(title: Text('音乐'), floating: true),
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
                  favoritesAvailable: favoritesPort != null,
                  favoriteMessage: favoriteMessage,
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
    required this.favoritesAvailable,
    required this.favoriteMessage,
    required this.onScan,
  });

  final RootGrant? grant;
  final String rootStatus;
  final MusicScanState scan;
  final bool favoritesAvailable;
  final String? favoriteMessage;
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
      label: Text(scan.isLoading ? '扫描中…' : '扫描音乐'),
    );

    final Widget status;
    if (grant == null && (rootStatus == 'error' || rootStatus == 'revoked')) {
      status = const SyncTuneStatusCard(
        title: '音乐根目录不可用',
        message: '授权已失效，请在设置中重新选择音乐根目录。',
        icon: Icons.folder_off_outlined,
        tone: SyncTuneStatusTone.error,
      );
    } else if (grant == null || rootStatus == 'none') {
      status = const SyncTuneStatusCard(
        title: '尚未选择音乐根目录',
        message: '请先在设置中选择一个音乐目录，SyncTune 只访问该目录。',
        icon: Icons.folder_outlined,
      );
    } else if (rootStatus == 'loading') {
      status = const SyncTuneStatusCard(
        title: '正在确认目录授权',
        message: '目录授权确认完成后才能开始扫描。',
        icon: Icons.hourglass_top_outlined,
      );
    } else if (scan.status == MusicScanStatus.loading) {
      status = const SyncTuneStatusCard(
        title: '正在扫描音乐',
        message: '正在读取已授权目录中的音乐文件，请稍候。',
        icon: Icons.sync_outlined,
        tone: SyncTuneStatusTone.warning,
      );
    } else if (scan.status == MusicScanStatus.failed) {
      status = SyncTuneStatusCard(
        title: '扫描未完成',
        message: '目录授权或读取状态发生变化，请重新选择目录后再试。',
        icon: Icons.error_outline,
        tone: SyncTuneStatusTone.error,
        action: scanButton,
      );
    } else if (scan.status == MusicScanStatus.ready && scan.tracks.isEmpty) {
      status = SyncTuneStatusCard(
        title: scan.complete ? '没有找到音乐文件' : '扫描不完整',
        message: scan.complete
            ? '仅显示 mp3、flac、wav、m4a、aac、ogg 和 opus 文件。'
            : '当前结果不能用于判断删除，请确认授权后重新扫描。',
        icon: scan.complete ? Icons.music_off_outlined : Icons.warning_amber,
        tone: scan.complete
            ? SyncTuneStatusTone.neutral
            : SyncTuneStatusTone.warning,
        action: scanButton,
      );
    } else if (scan.status == MusicScanStatus.ready && !scan.complete) {
      status = SyncTuneStatusCard(
        title: '扫描不完整',
        message: '已显示当前可读取的文件。完整扫描前不会据此安排删除操作。',
        icon: Icons.warning_amber,
        tone: SyncTuneStatusTone.warning,
        action: scanButton,
      );
    } else {
      status = SyncTuneStatusCard(
        title: '可以扫描音乐',
        message: '仅访问你选择的授权目录，支持 mp3、flac、wav、m4a、aac、ogg 和 opus。',
        icon: Icons.folder_shared_outlined,
        tone: SyncTuneStatusTone.positive,
        action: scanButton,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('音乐库', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: SyncTuneTokens.space8),
        Text(
          grant == null ? '选择授权目录后开始扫描。' : '目录：${grant!.path}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: SyncTuneTokens.space16),
        status,
        const SizedBox(height: SyncTuneTokens.space12),
        const Text('SyncTune 只同步音乐文件，不播放或编辑音乐。'),
        if (!favoritesAvailable) ...[
          const SizedBox(height: SyncTuneTokens.space8),
          const Text('收藏功能将在本地元数据服务连接后启用。'),
        ],
        if (favoriteMessage != null) ...[
          const SizedBox(height: SyncTuneTokens.space12),
          SyncTuneStatusCard(
            title: '收藏状态',
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
            child: Text('文件', style: Theme.of(context).textTheme.labelLarge),
          ),
          const SizedBox(width: 120, child: Text('格式')),
          const SizedBox(width: 120, child: Text('大小')),
          const SizedBox(width: 48, child: Text('收藏')),
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
  });

  final MusicTrack track;
  final bool expanded;
  final bool favorite;
  final VoidCallback? onFavorite;

  @override
  Widget build(BuildContext context) {
    final star = IconButton(
      tooltip: onFavorite == null
          ? '收藏服务尚未连接'
          : favorite
          ? '取消收藏'
          : '收藏',
      onPressed: onFavorite,
      icon: Icon(favorite ? Icons.star : Icons.star_border),
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
          trailing: star,
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
          SizedBox(width: 120, child: Text(track.extension.toUpperCase())),
          SizedBox(width: 120, child: Text(formatBytes(track.size))),
          SizedBox(width: 48, child: star),
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
