import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sync_tune_database.dart';
import '../localization/strings.dart';
import '../sync/sync_gate.dart';
import '../sync/sync_status_view_model.dart';
import 'music_scan.dart';

/// App port for single-song deletion with cross-device sync.
abstract interface class MusicDeletionPort {
  /// Deletes a song from local storage and schedules its WebDAV deletion.
  Future<void> deleteSong({
    required String relativePath,
    required String expectedSha256,
    String? entryId,
  });

  /// Loads pending deletion tasks for the currently active root.
  Future<List<DeletionTaskRecord>> pendingTasks();

  /// Recovers any interrupted deletion tasks.
  Future<void> recoverTasks();
}

final musicDeletionPortProvider = Provider<MusicDeletionPort?>((ref) => null);

final class MusicDeletionState {
  const MusicDeletionState({
    this.isDeleting = false,
    this.deletingPath,
    this.pendingSyncPaths = const <String>{},
    this.statusMessage,
    this.errorMessage,
  });

  final bool isDeleting;
  final String? deletingPath;
  final Set<String> pendingSyncPaths;
  final String? statusMessage;
  final String? errorMessage;

  MusicDeletionState copyWith({
    bool? isDeleting,
    String? deletingPath,
    Set<String>? pendingSyncPaths,
    String? statusMessage,
    String? errorMessage,
    bool clearStatusMessage = false,
    bool clearErrorMessage = false,
  }) {
    return MusicDeletionState(
      isDeleting: isDeleting ?? this.isDeleting,
      deletingPath: deletingPath ?? this.deletingPath,
      pendingSyncPaths: pendingSyncPaths ?? this.pendingSyncPaths,
      statusMessage:
          clearStatusMessage ? null : (statusMessage ?? this.statusMessage),
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

final class MusicDeletionViewModel extends Notifier<MusicDeletionState> {
  bool _disposed = false;

  @override
  MusicDeletionState build() {
    ref.onDispose(() => _disposed = true);

    ref.listen(syncRuntimeSnapshotProvider, (previous, next) {
      if (_disposed) return;
      final prevPhase = previous?.asData?.value.phase;
      final nextPhase = next.asData?.value.phase;
      if (nextPhase == ForegroundRunPhase.succeeded &&
          prevPhase != ForegroundRunPhase.succeeded) {
        checkPendingTasks();
      }
    });

    ref.listen(rootGrantProvider, (previous, next) {
      if (_disposed) return;
      if (previous?.token != next?.token ||
          previous?.generation != next?.generation) {
        state = const MusicDeletionState();
        checkPendingTasks();
      }
    });

    // Check pending tasks asynchronously after initialization.
    Future.microtask(() => checkPendingTasks());

    return const MusicDeletionState();
  }

  Future<void> checkPendingTasks() async {
    final port = ref.read(musicDeletionPortProvider);
    if (port == null) return;
    try {
      final tasks = await port.pendingTasks();
      if (_disposed) return;
      if (tasks.isEmpty) {
        if (state.pendingSyncPaths.isNotEmpty || state.statusMessage != null) {
          state = state.copyWith(
            pendingSyncPaths: const <String>{},
            clearStatusMessage: true,
          );
        }
      } else {
        final pendingPaths = tasks.map((t) => t.relativePath).toSet();
        state = state.copyWith(
          pendingSyncPaths: pendingPaths,
          statusMessage: 'Local file deleted, waiting to sync',
        );
      }
    } catch (_) {}
  }

  Future<bool> confirmAndDelete(
    BuildContext context,
    MusicTrack track, {
    required RootGrant grant,
  }) async {
    final runtimeSnapshot =
        ref.read(syncRuntimeSnapshotProvider).asData?.value ??
            const ForegroundRuntimeSnapshot.idle();
    if (runtimeSnapshot.isRunning || state.isDeleting) {
      return false;
    }

    final strings = SyncTuneStrings.of(context);
    final fileName = track.relativePath.split('/').last;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const LocalizedText('Delete song'),
          content: Text(
            '$fileName\n\n${strings.text('Delete local song and WebDAV copy. Other devices will delete it on their next sync.')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const LocalizedText('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const LocalizedText('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return false;
    if (_disposed) return false;

    final port = ref.read(musicDeletionPortProvider);
    if (port == null) {
      state = state.copyWith(
        errorMessage: 'Deletion service is not connected.',
      );
      return false;
    }

    state = state.copyWith(
      isDeleting: true,
      deletingPath: track.relativePath,
      clearErrorMessage: true,
    );

    try {
      await port.deleteSong(
        relativePath: track.relativePath,
        expectedSha256: track.sha256 ?? '',
        entryId: track.id,
      );

      if (_disposed) return true;

      // Local delete succeeded! Immediately remove from music scan list
      ref.read(musicScanProvider.notifier).removeTrack(track.relativePath);

      // Check pending tasks status
      await checkPendingTasks();
      return true;
    } catch (error) {
      if (_disposed) return false;
      // Local failed: retain song in list and display reason
      state = state.copyWith(
        errorMessage: error.toString(),
      );
      return false;
    } finally {
      if (!_disposed) {
        state = state.copyWith(
          isDeleting: false,
          deletingPath: null,
        );
      }
    }
  }
}

final musicDeletionProvider =
    NotifierProvider<MusicDeletionViewModel, MusicDeletionState>(
  MusicDeletionViewModel.new,
);
