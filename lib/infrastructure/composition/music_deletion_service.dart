import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import '../../app/music/music_deletion.dart';
import '../../data/sync_tune_database.dart';
import '../runtime/foreground_sync_runtime.dart';
import 'synctune_composition.dart';

/// Production implementation of [MusicDeletionPort].
/// Connects the database, platform local object store, target tracking,
/// and foreground sync runtime.
final class SyncTuneMusicDeletionService implements MusicDeletionPort {
  SyncTuneMusicDeletionService({
    required this.database,
    required this.local,
    required this.targets,
    required this.runtime,
  });

  final SyncTuneDatabase database;
  final LocalObjectStore local;
  final CompositionTargetPort targets;
  final ForegroundSyncRuntime runtime;

  @override
  Future<void> deleteSong({
    required String relativePath,
    required String expectedSha256,
    String? entryId,
  }) async {
    if (runtime.isBusy) {
      throw const SyncRuntimeNotReady('Sync is currently running.');
    }
    final target = targets.current;
    if (target == null) {
      throw StateError('No authorized music root folder is active.');
    }
    final root = SyncRoot(
      target.rootToken,
      generation: target.rootGeneration,
      remoteNamespace: target.configEpoch,
    );
    final syncPath = SyncPath.parse(relativePath);
    final catalogEntry = await database.loadCatalogEntry(root, syncPath);
    final actualEntryId = entryId ??
        catalogEntry?.id ??
        await database.ensureCatalogEntryId(root, syncPath);

    String finalSha256 = expectedSha256;
    if (finalSha256.isEmpty) {
      finalSha256 = catalogEntry?.sha256 ?? '';
    }
    if (finalSha256.isEmpty) {
      finalSha256 = await _computeSha256(local, syncPath);
    }

    final operationId = 'del-${DateTime.now().microsecondsSinceEpoch}';
    final task = DeletionTaskRecord(
      operationId: operationId,
      rootId: root.storageKey,
      generation: root.generation,
      remoteNamespace: root.remoteNamespace,
      entryId: actualEntryId,
      relativePath: relativePath,
      expectedSha256: finalSha256,
      stage: 'pending_local',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await database.saveDeletionTask(task);

    // Mutual exclusion: deletion shares the runtime execution slot with sync.
    await runtime.runExclusive(() async {
      final tombstone = SyncEntry.tombstone(
        id: actualEntryId,
        path: syncPath,
        modifiedAtUtc: DateTime.now().toUtc(),
        revision: (catalogEntry?.revision ?? 0) + 1,
        favorite: catalogEntry?.favorite ??
            const FavoriteStamp(value: false, lamport: 0, deviceId: ''),
      );

      await local.delete(
        syncPath,
        condition: LocalMatchSha256(finalSha256),
        tombstone: tombstone,
        operationId: operationId,
      );

      await database.updateDeletionTaskStage(operationId, 'local_deleted');
    });

    // Auto-trigger sync after successful local deletion.
    try {
      await runtime.run();
    } catch (_) {
      // Offline or sync failed; local delete remains intact and task will be retried.
    }
  }

  @override
  Future<List<DeletionTaskRecord>> pendingTasks() async {
    final target = targets.current;
    if (target == null) return const [];
    final root = SyncRoot(
      target.rootToken,
      generation: target.rootGeneration,
      remoteNamespace: target.configEpoch,
    );
    return database.loadPendingDeletionTasks(
      rootId: root.storageKey,
      generation: target.rootGeneration,
      remoteNamespace: target.configEpoch,
    );
  }

  @override
  Future<void> recoverTasks() async {
    final target = targets.current;
    if (target == null) return;
    final root = SyncRoot(
      target.rootToken,
      generation: target.rootGeneration,
      remoteNamespace: target.configEpoch,
    );
    final pending = await database.loadPendingDeletionTasks(
      rootId: root.storageKey,
      generation: target.rootGeneration,
      remoteNamespace: target.configEpoch,
    );
    if (pending.isEmpty) return;

    for (final task in pending) {
      if (task.stage == 'pending_local') {
        final syncPath = SyncPath.parse(task.relativePath);
        final catalogEntry = await database.loadCatalogEntry(root, syncPath);
        final tombstone = SyncEntry.tombstone(
          id: task.entryId,
          path: syncPath,
          modifiedAtUtc: DateTime.now().toUtc(),
          revision: (catalogEntry?.revision ?? 0) + 1,
          favorite: catalogEntry?.favorite ??
              const FavoriteStamp(value: false, lamport: 0, deviceId: ''),
        );
        try {
          await runtime.runExclusive(() async {
            await local.delete(
              syncPath,
              condition: LocalMatchSha256(task.expectedSha256),
              tombstone: tombstone,
              operationId: task.operationId,
            );
            await database.updateDeletionTaskStage(
              task.operationId,
              'local_deleted',
            );
          });
        } catch (_) {
          // If the file was already deleted or changed, ensure tombstone is saved
          await local.saveTombstone(syncPath, tombstone);
          await database.updateDeletionTaskStage(
            task.operationId,
            'local_deleted',
          );
        }
      }
    }

    try {
      await runtime.run();
    } catch (_) {}
  }

  static Future<String> _computeSha256(
    LocalObjectStore store,
    SyncPath path,
  ) async {
    final stream = await store.read(path);
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }
}
