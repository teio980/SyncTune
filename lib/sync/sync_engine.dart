import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'local_store.dart';
import 'state_store.dart';
import 'sync_model.dart';
import 'sync_planner.dart';
import 'webdav_client.dart';

typedef SyncProgressCallback = FutureOr<void> Function(SyncProgress progress);

/// Runs one serialized, manually requested synchronization.
///
/// It stores one recoverable operation at a time. A failed or cancelled
/// operation stays in SQLite and is reconciled against both stores at the next
/// manual start; the engine never persists or replays a whole sync plan.
final class SyncEngine {
  SyncEngine({
    required this.localStore,
    required this.webDav,
    required this.stateStore,
  });

  final LocalStore localStore;
  final WebDavClient webDav;
  final SqliteStateStore stateStore;
  final SyncPlanner _planner = const SyncPlanner();
  bool _running = false;

  Future<void> testConnection(
    SyncSettings settings, {
    required String secret,
    required CancellationToken cancellation,
  }) => webDav.testConnection(settings, secret: secret, token: cancellation);

  Future<void> run(
    SyncSettings settings, {
    required String secret,
    required CancellationToken cancellation,
    SyncProgressCallback? onProgress,
  }) async {
    if (_running) {
      throw const SyncFailure('A synchronization is already running.');
    }
    _running = true;
    var progress = const SyncProgress(phase: SyncPhase.recovering);
    var networkBytesDone = 0;
    int? networkBytesTotal;
    var transferPlanReady = false;
    Future<void> report(SyncProgress next) async {
      progress = next;
      await onProgress?.call(next);
    }

    Future<void> onNetworkBytes(SyncPath path, int bytes) async {
      if (!transferPlanReady) return;
      networkBytesDone += bytes;
      final plannedTotal = networkBytesTotal;
      if (plannedTotal != null && networkBytesDone > plannedTotal) {
        // A changed source no longer fits the scan estimate. Keep the actual
        // byte count and stop claiming a known denominator.
        networkBytesTotal = null;
      }
      await report(
        progress.copyWith(
          currentFile: path.value,
          bytesDone: networkBytesDone,
          totalBytes: networkBytesTotal,
          clearTotalBytes: networkBytesTotal == null,
        ),
      );
    }

    Directory? cache;
    Object? primaryFailure;
    try {
      final configuredStore = localStore;
      if (configuredStore is ConfigurableLocalStore) {
        configuredStore.configure(settings);
      }
      await stateStore.open();
      stateStore.ensureIdentity(settings.syncIdentity);
      webDav.setSecret(secret);
      final support = Directory(File(stateStore.databasePath).parent.path);
      final remoteBackupDirectory = Directory(
        '${support.path}${Platform.pathSeparator}sync-v2${Platform.pathSeparator}remote',
      );
      await remoteBackupDirectory.create(recursive: true);
      cache = await Directory.systemTemp.createTemp('synctune-sync-');

      await report(
        progress.copyWith(
          phase: SyncPhase.recovering,
          currentFile: '',
          error: '',
        ),
      );
      for (final pending in stateStore.loadPending()) {
        cancellation.throwIfCancelled();
        if (pending.needsRescan) {
          await _cleanup(pending, cancellation, forRescan: true);
          continue;
        }
        if (pending.complete) {
          await _cleanup(pending, cancellation);
          continue;
        }
        await report(
          progress.copyWith(
            phase: SyncPhase.recovering,
            currentFile: pending.path.value,
          ),
        );
        await _recoverOne(
          settings,
          pending,
          cache,
          cancellation,
          onNetworkBytes,
        );
      }

      cancellation.throwIfCancelled();
      await report(
        progress.copyWith(
          phase: SyncPhase.scanning,
          currentFile: '',
          filesDone: 0,
          bytesDone: 0,
          clearFileCount: true,
          clearTotalBytes: true,
        ),
      );
      final baseline = stateStore.loadBaseline();
      var scanBytes = 0;
      final scannedPaths = <String>{};
      var scanFiles = 0;
      Future<void> scanByte(SyncPath path, int bytes) async {
        scanBytes += bytes;
        await report(
          progress.copyWith(
            phase: SyncPhase.scanning,
            currentFile: path.value,
            filesDone: scanFiles,
            bytesDone: scanBytes,
            clearFileCount: true,
            clearTotalBytes: true,
          ),
        );
      }

      Future<void> scanFile(SyncPath path) async {
        if (scannedPaths.add(path.value)) scanFiles++;
        await report(
          progress.copyWith(
            phase: SyncPhase.scanning,
            currentFile: path.value,
            filesDone: scanFiles,
            clearFileCount: true,
            clearTotalBytes: true,
          ),
        );
      }

      final localScan = await localStore.scan(
        cancellation,
        onBytes: scanByte,
        onFile: scanFile,
      );
      cancellation.throwIfCancelled();
      await webDav.ensureRoot(settings, cancellation);
      final remoteScan = await webDav.scan(
        settings,
        baseline,
        cache,
        cancellation,
        onMusicFile: scanFile,
        onBytes: scanByte,
      );
      cancellation.throwIfCancelled();

      final local = indexFiles(localScan.files, windowsCaseSensitive: false);
      final remote = indexFiles(remoteScan.files, windowsCaseSensitive: false);
      final plan = _planner.plan(
        local: local,
        remote: remote,
        baseline: baseline,
      );
      validateSyncTargetPaths(
        plan.map((item) => item.path),
        local: localScan.occupiedPaths,
        remote: remoteScan.occupiedPaths,
      );
      networkBytesDone = 0;
      networkBytesTotal = plan.fold<int>(0, (sum, item) {
        final expected = item.sha256;
        if (expected == null) return sum;
        final needsLocal = local[item.path]?.sha256 != expected;
        final needsRemote = remote[item.path]?.sha256 != expected;
        var bytes = sum;
        // A WebDAV PUT is the only network work needed to update the remote
        // target, regardless of which side supplied its staged content.
        if (needsRemote) bytes += item.size;
        if (needsLocal && item.sourceSide == ContentSide.remote) {
          final sourcePath = item.sourcePath;
          final source = sourcePath == null ? null : remote[sourcePath];
          // A file already downloaded into the scan cache was read during
          // scanning and does not consume another GET during this operation.
          if (source?.cachedFile == null) bytes += item.size;
        }
        return bytes;
      });
      transferPlanReady = true;
      await report(
        progress.copyWith(
          phase: SyncPhase.comparing,
          currentFile: '',
          fileCount: plan.length,
          filesDone: 0,
          totalBytes: networkBytesTotal,
          bytesDone: 0,
        ),
      );

      var filesDone = 0;
      for (final desired in plan) {
        cancellation.throwIfCancelled();
        await report(
          progress.copyWith(
            phase: SyncPhase.transferring,
            currentFile: desired.path.value,
            fileCount: plan.length,
            filesDone: filesDone,
            totalBytes: networkBytesTotal,
            bytesDone: networkBytesDone,
          ),
        );
        await _applyDecision(
          settings,
          desired,
          local[desired.path],
          remote[desired.path],
          baseline,
          remote,
          remoteBackupDirectory,
          cache,
          cancellation,
          onNetworkBytes,
        );
        filesDone++;
        await report(
          progress.copyWith(
            phase: SyncPhase.transferring,
            currentFile: desired.path.value,
            fileCount: plan.length,
            filesDone: filesDone,
            totalBytes: networkBytesTotal,
            bytesDone: networkBytesDone,
          ),
        );
      }
      cancellation.throwIfCancelled();
      await report(
        progress.copyWith(
          phase: SyncPhase.verifying,
          currentFile: '',
          filesDone: 0,
          bytesDone: 0,
          clearFileCount: true,
          clearTotalBytes: true,
        ),
      );
      final verifiedFileCount = await _verifyWholeTree(
        settings,
        cache,
        cancellation,
        report,
      );
      cancellation.throwIfCancelled();
      await report(
        progress.copyWith(
          phase: SyncPhase.complete,
          currentFile: '',
          filesDone: verifiedFileCount,
          fileCount: verifiedFileCount,
          bytesDone: networkBytesDone,
          totalBytes: networkBytesTotal,
          error: '',
        ),
      );
    } catch (error) {
      primaryFailure = error;
      rethrow;
    } finally {
      webDav.clearSecret();
      if (cache != null && await cache.exists()) {
        try {
          await cache.delete(recursive: true);
        } catch (error) {
          if (primaryFailure == null) {
            _running = false;
            throw SyncFailure(
              'Could not remove the temporary WebDAV comparison cache: $error',
            );
          }
        }
      }
      _running = false;
    }
  }

  Future<void> _recoverOne(
    SyncSettings settings,
    PendingOperation operation,
    Directory cache,
    CancellationToken cancellation,
    SyncByteProgress onNetworkBytes,
  ) async {
    final baseline = stateStore.loadBaseline();
    final localHash = await localStore.hash(operation.path, cancellation);
    final remote = await webDav.inspect(
      settings,
      operation.path,
      const <SyncPath, BaselineEntry>{},
      cache,
      cancellation,
    );
    try {
      final remoteHash = remote?.sha256;
      final localExpected = operation.expectedLocalHash;
      final remoteExpected = operation.expectedRemoteHash;
      final localPrevious = operation.previousLocalHash;
      final remotePrevious = operation.previousRemoteHash;
      final localBackupValid = await _localBackupValid(
        operation,
        localPrevious,
        cancellation,
      );
      final localPartialCommit =
          localExpected != null &&
          await localStore.canResumeCommit(
            operation.path,
            operation.id,
            localExpected,
            localPrevious,
            cancellation,
          );

      final localCanContinue =
          localHash == localExpected ||
          localHash == localPrevious ||
          (localHash == null && localPrevious != null && localBackupValid) ||
          localPartialCommit;
      final remoteCanContinue =
          remoteHash == remoteExpected || remoteHash == remotePrevious;
      if (!localCanContinue) {
        throw SyncFailure(
          'The local file changed during an interrupted operation; recovery data was kept.',
          path: operation.path,
        );
      }
      if (!remoteCanContinue) {
        // Older versions did not mark a rejected backup GET for a rescan.
        // Reconcile those journals only while the local target is unchanged,
        // no local commit is partial, and neither side is marked committed.
        await _markRescanIfUntouched(operation, cancellation);
        final pending = stateStore.loadPending().firstWhere(
          (item) => item.id == operation.id,
        );
        if (pending.needsRescan) {
          await _cleanup(pending, cancellation, forRescan: true);
          return;
        }
        throw SyncFailure(
          'The WebDAV file changed during an interrupted operation; recovery data was kept.',
          path: operation.path,
        );
      }
      if (localHash == localExpected) {
        stateStore.markSide(operation.id, local: true);
      }
      if (remoteHash == remoteExpected) {
        stateStore.markSide(operation.id, local: false);
      }

      await _continueOperation(
        settings,
        operation,
        baseline,
        cache,
        cancellation,
        onNetworkBytes: onNetworkBytes,
      );
    } finally {
      final file = remote?.cachedFile;
      if (file != null && await file.exists()) await file.delete();
    }
  }

  Future<void> _applyDecision(
    SyncSettings settings,
    DesiredPath desired,
    SyncFile? local,
    SyncFile? remote,
    Map<SyncPath, BaselineEntry> baseline,
    Map<SyncPath, SyncFile> remoteFiles,
    Directory remoteBackupDirectory,
    Directory cache,
    CancellationToken cancellation,
    SyncByteProgress onNetworkBytes,
  ) async {
    final localHash = local?.sha256;
    final remoteHash = remote?.sha256;
    if (localHash != desired.previousLocalHash && localHash != desired.sha256) {
      throw SyncFailure(
        'The local scan no longer matches its synchronization decision.',
        path: desired.path,
      );
    }
    if (remoteHash != desired.previousRemoteHash &&
        remoteHash != desired.sha256) {
      throw SyncFailure(
        'The WebDAV scan no longer matches its synchronization decision.',
        path: desired.path,
      );
    }
    if (desired.sha256 != null &&
        localHash == desired.sha256 &&
        remoteHash == desired.sha256) {
      final modified = local?.modifiedMs ?? 0;
      stateStore.saveUnchangedBaseline(
        BaselineEntry(
          path: desired.path,
          sha256: desired.sha256!,
          localModifiedMs: modified,
          remoteEtag: remote?.etag,
          remoteSize: remote?.size ?? desired.size,
        ),
      );
      return;
    }
    if (desired.sha256 == null && localHash == null && remoteHash == null) {
      stateStore.deleteUnchangedBaseline(desired.path);
      return;
    }

    final id = _newOperationId();
    final operation = PendingOperation(
      id: id,
      path: desired.path,
      kind: desired.sha256 == null ? 'delete' : 'write',
      expectedLocalHash: desired.sha256,
      expectedRemoteHash: desired.sha256,
      expectedSize: desired.size,
      previousLocalHash: desired.previousLocalHash,
      previousRemoteHash: desired.previousRemoteHash,
      previousRemoteEtag: desired.remoteEtag,
      sourcePath: desired.sourcePath,
      sourceSide: desired.sourceSide?.name,
      localStage: localStore.stageKey(id),
      localBackup: localStore.backupKey(id),
      remoteBackup: _remoteBackupPath(remoteBackupDirectory, id),
    );
    stateStore.begin(operation);
    await _continueOperation(
      settings,
      operation,
      baseline,
      cache,
      cancellation,
      onNetworkBytes: onNetworkBytes,
      remoteWasScanned: true,
      scannedRemote: remote,
      scannedRemoteSource:
          desired.sourceSide == ContentSide.remote && desired.sourcePath != null
          ? remoteFiles[desired.sourcePath]
          : null,
    );
  }

  Future<void> _continueOperation(
    SyncSettings settings,
    PendingOperation operation,
    Map<SyncPath, BaselineEntry> baseline,
    Directory cache,
    CancellationToken cancellation, {
    required SyncByteProgress onNetworkBytes,
    bool remoteWasScanned = false,
    SyncFile? scannedRemote,
    SyncFile? scannedRemoteSource,
  }) async {
    cancellation.throwIfCancelled();
    final expected = operation.expectedLocalHash;
    if (expected != operation.expectedRemoteHash) {
      throw SyncFailure(
        'The recovery log contains different local and WebDAV content.',
        path: operation.path,
      );
    }
    final stageKey = operation.localStage ?? operation.id;
    final backupKey = operation.localBackup ?? operation.id;
    final remoteBackup = operation.remoteBackup;
    if (stageKey != operation.id || backupKey != operation.id) {
      throw SyncFailure(
        'The recovery log points outside the operation-owned staging files.',
        path: operation.path,
      );
    }
    if (remoteBackup == null) {
      throw SyncFailure(
        'The recovery log has no WebDAV backup path.',
        path: operation.path,
      );
    }
    if (_canonical(remoteBackup) !=
        _canonical(_expectedRemoteBackupPath(operation.id))) {
      throw SyncFailure(
        'The recovery log points outside the operation-owned WebDAV backup.',
        path: operation.path,
      );
    }

    final remoteBefore = remoteWasScanned
        ? scannedRemote
        : await webDav.inspect(
            settings,
            operation.path,
            baseline,
            cache,
            cancellation,
          );
    SyncFile? uploadedVerification;
    try {
      final remoteHash = remoteBefore?.sha256;
      final expectedRemote = operation.expectedRemoteHash;
      final previousRemote = operation.previousRemoteHash;
      if (remoteHash != expectedRemote && remoteHash != previousRemote) {
        throw SyncFailure(
          'The WebDAV file changed while an operation was pending; recovery data was kept.',
          path: operation.path,
        );
      }
      if (remoteHash == expectedRemote) {
        // Reconfirm below after the local side reaches its stop point.
      } else if (expectedRemote == null) {
        if (remoteBefore == null) {
          // It is already absent; the final metadata check confirms it again.
        } else {
          if (previousRemote == null) {
            throw SyncFailure(
              'The WebDAV delete target could not be verified.',
              path: operation.path,
            );
          }
          try {
            await webDav.delete(
              settings,
              operation.path,
              previousRemote,
              operation.previousRemoteEtag,
              remoteBackup,
              cancellation,
            );
          } on SyncFailure catch (error) {
            if (error.statusCode == HttpStatus.preconditionFailed) {
              // The conditional backup GET can fail before DELETE is sent.
              await _markRescanIfUntouched(operation, cancellation);
            }
            rethrow;
          }
        }
      } else {
        await _ensureStage(
          operation,
          settings,
          cache,
          cancellation,
          onNetworkBytes,
          scannedRemoteSource,
        );
        await webDav.ensureParents(settings, operation.path, cancellation);
        final staged = await localStore.readStage(operation.id, cancellation);
        try {
          await webDav.put(
            settings,
            operation.path,
            staged,
            operation.expectedSize,
            previousRemote,
            operation.previousRemoteEtag,
            remoteBackup,
            cancellation,
            onBytes: onNetworkBytes,
          );
        } on SyncFailure catch (error) {
          if (error.statusCode == HttpStatus.preconditionFailed) {
            // A rejected backup GET also leaves both targets untouched.
            await _markRescanIfUntouched(operation, cancellation);
          }
          rethrow;
        }
        uploadedVerification = await webDav.inspect(
          settings,
          operation.path,
          const <SyncPath, BaselineEntry>{},
          cache,
          cancellation,
        );
        if (uploadedVerification?.sha256 != expectedRemote) {
          throw SyncFailure(
            'Uploaded WebDAV content failed SHA-256 verification.',
            path: operation.path,
          );
        }
      }
    } finally {
      final file = remoteBefore?.cachedFile;
      if (file != null && await file.exists()) await file.delete();
    }

    cancellation.throwIfCancelled();
    final currentLocal = await localStore.hash(operation.path, cancellation);
    final previousLocal = operation.previousLocalHash;
    final localBackupValid = await _localBackupValid(
      operation,
      previousLocal,
      cancellation,
    );
    final localPartialCommit =
        expected != null &&
        await localStore.canResumeCommit(
          operation.path,
          operation.id,
          expected,
          previousLocal,
          cancellation,
        );
    if (currentLocal != expected &&
        currentLocal != previousLocal &&
        !(currentLocal == null && previousLocal != null && localBackupValid) &&
        !localPartialCommit) {
      throw SyncFailure(
        'The local file changed while an operation was pending; recovery data was kept.',
        path: operation.path,
      );
    }
    if (currentLocal == expected) {
      stateStore.markSide(operation.id, local: true);
    } else if (expected == null) {
      if (currentLocal != null) {
        if (previousLocal == null) {
          throw SyncFailure(
            'The local delete target changed during recovery.',
            path: operation.path,
          );
        }
        await localStore.deleteVerified(
          operation.path,
          backupKey,
          previousLocal,
          cancellation,
        );
      }
      stateStore.markSide(operation.id, local: true);
    } else {
      await _ensureStage(
        operation,
        settings,
        cache,
        cancellation,
        onNetworkBytes,
      );
      await localStore.commit(
        operation.path,
        stageKey,
        backupKey,
        expected,
        operation.previousLocalHash,
        cancellation,
      );
      if (await localStore.hash(operation.path, cancellation) != expected) {
        throw SyncFailure(
          'Committed local file failed SHA-256 verification.',
          path: operation.path,
        );
      }
      stateStore.markSide(operation.id, local: true);
    }

    cancellation.throwIfCancelled();
    final verifiedLocal = await localStore.hash(operation.path, cancellation);
    final finalRemote =
        uploadedVerification ??
        await webDav.inspect(
          settings,
          operation.path,
          _verificationBaseline(operation.path, remoteBefore),
          cache,
          cancellation,
        );
    try {
      if (verifiedLocal != operation.expectedLocalHash ||
          finalRemote?.sha256 != operation.expectedRemoteHash) {
        throw SyncFailure(
          'The two stores do not match the pending operation; recovery data was kept.',
          path: operation.path,
        );
      }
      stateStore.markSide(operation.id, local: true);
      stateStore.markSide(operation.id, local: false);
      final modified = await localStore.modifiedMs(operation.path) ?? 0;
      final entry = expected == null
          ? null
          : BaselineEntry(
              path: operation.path,
              sha256: expected,
              localModifiedMs: modified,
              remoteEtag: finalRemote?.etag,
              remoteSize: finalRemote?.size ?? operation.expectedSize,
            );
      stateStore.finishPath(operation.id, entry);
    } finally {
      final file = finalRemote?.cachedFile;
      if (file != null && await file.exists()) await file.delete();
    }

    final complete = stateStore
        .loadPending()
        .where((item) => item.id == operation.id)
        .firstOrNull;
    if (complete != null) await _cleanup(complete, cancellation);
  }

  Map<SyncPath, BaselineEntry> _verificationBaseline(
    SyncPath path,
    SyncFile? observed,
  ) {
    if (observed == null || !observed.hasStrongEtag) {
      return const <SyncPath, BaselineEntry>{};
    }
    return <SyncPath, BaselineEntry>{
      path: BaselineEntry(
        path: path,
        sha256: observed.sha256,
        localModifiedMs: observed.modifiedMs,
        remoteEtag: observed.etag,
        remoteSize: observed.size,
      ),
    };
  }

  Future<void> _ensureStage(
    PendingOperation operation,
    SyncSettings settings,
    Directory cache,
    CancellationToken cancellation,
    SyncByteProgress onNetworkBytes, [
    SyncFile? scannedRemoteSource,
  ]) async {
    final expected = operation.expectedLocalHash;
    if (expected == null) return;
    final current = await localStore.stageHash(operation.id, cancellation);
    if (current == expected) return;
    final sourcePath = operation.sourcePath;
    final sourceSide = operation.sourceSide;
    if (sourcePath == null ||
        (sourceSide != 'local' && sourceSide != 'remote')) {
      throw SyncFailure(
        'The recovery log has no valid source for the pending file.',
        path: operation.path,
      );
    }
    Stream<List<int>> source;
    File? disposable;
    if (sourceSide == 'local') {
      if (await localStore.hash(sourcePath, cancellation) != expected) {
        throw SyncFailure(
          'The local source changed before it could be staged.',
          path: sourcePath,
        );
      }
      source = await localStore.read(sourcePath, cancellation);
    } else {
      final cached =
          scannedRemoteSource?.path == sourcePath &&
              scannedRemoteSource?.sha256 == expected
          ? scannedRemoteSource?.cachedFile
          : null;
      if (cached != null && await cached.exists()) {
        disposable = cached;
        source = cached.openRead();
      } else {
        final sourceFile =
            scannedRemoteSource?.path == sourcePath &&
                scannedRemoteSource?.sha256 == expected
            ? scannedRemoteSource!
            : SyncFile(
                path: sourcePath,
                sha256: expected,
                size: operation.expectedSize,
                etag: operation.previousRemoteEtag,
              );
        disposable = sourceFile.cachedFile;
        if (disposable == null) {
          final read = await webDav.prepareSource(
            settings,
            sourceFile,
            cache,
            cancellation,
            onBytes: onNetworkBytes,
          );
          disposable = read;
        }
        source = disposable.openRead();
      }
    }
    try {
      await localStore.stage(operation.id, source, expected, cancellation);
      if (await localStore.stageHash(operation.id, cancellation) != expected) {
        throw SyncFailure(
          'The staged content failed SHA-256 verification.',
          path: operation.path,
        );
      }
    } finally {
      if (disposable != null && await disposable.exists()) {
        await disposable.delete();
      }
    }
  }

  Future<int> _verifyWholeTree(
    SyncSettings settings,
    Directory cache,
    CancellationToken cancellation,
    SyncProgressCallback onProgress,
  ) async {
    final baseline = stateStore.loadBaseline();
    var scanBytes = 0;
    var scanFiles = 0;
    final scannedPaths = <String>{};
    Future<void> scanByte(SyncPath path, int bytes) async {
      scanBytes += bytes;
      await onProgress(
        SyncProgress(
          phase: SyncPhase.verifying,
          currentFile: path.value,
          filesDone: scanFiles,
          bytesDone: scanBytes,
        ),
      );
    }

    Future<void> scanFile(SyncPath path) async {
      if (scannedPaths.add(path.value)) scanFiles++;
      await onProgress(
        SyncProgress(
          phase: SyncPhase.verifying,
          currentFile: path.value,
          filesDone: scanFiles,
          bytesDone: scanBytes,
        ),
      );
    }

    final localScan = await localStore.scan(
      cancellation,
      onBytes: scanByte,
      onFile: scanFile,
    );
    cancellation.throwIfCancelled();
    final remoteScan = await webDav.scan(
      settings,
      baseline,
      cache,
      cancellation,
      onMusicFile: scanFile,
      onBytes: scanByte,
    );
    cancellation.throwIfCancelled();
    final local = indexFiles(localScan.files, windowsCaseSensitive: false);
    final remote = indexFiles(remoteScan.files, windowsCaseSensitive: false);
    final allPaths = <SyncPath>{
      ...local.keys,
      ...remote.keys,
      ...baseline.keys,
    };
    validateSyncTargetPaths(
      allPaths,
      local: localScan.occupiedPaths,
      remote: remoteScan.occupiedPaths,
    );
    await onProgress(
      SyncProgress(
        phase: SyncPhase.verifying,
        fileCount: allPaths.length,
        filesDone: 0,
      ),
    );
    var verifiedFiles = 0;
    for (final path in allPaths) {
      cancellation.throwIfCancelled();
      final localHash = local[path]?.sha256;
      final remoteHash = remote[path]?.sha256;
      final baselineHash = baseline[path]?.sha256;
      if (localHash == null ||
          remoteHash == null ||
          localHash != remoteHash ||
          localHash != baselineHash) {
        throw SyncFailure(
          'The file changed during final verification; start another manual sync.',
          path: path,
        );
      }
      verifiedFiles++;
      await onProgress(
        SyncProgress(
          phase: SyncPhase.verifying,
          currentFile: path.value,
          filesDone: verifiedFiles,
          fileCount: allPaths.length,
        ),
      );
    }
    await onProgress(
      SyncProgress(
        phase: SyncPhase.verifying,
        filesDone: verifiedFiles,
        fileCount: allPaths.length,
      ),
    );
    return verifiedFiles;
  }

  Future<bool> _localBackupValid(
    PendingOperation operation,
    String? expected,
    CancellationToken cancellation,
  ) async {
    if (expected == null) return false;
    return await localStore.backupHash(operation.id, cancellation) == expected;
  }

  Future<void> _cleanup(
    PendingOperation operation,
    CancellationToken cancellation, {
    bool forRescan = false,
  }) async {
    await localStore.cleanup(operation, cancellation);
    if (operation.remoteBackup != null) {
      if (_canonical(operation.remoteBackup!) !=
          _canonical(_expectedRemoteBackupPath(operation.id))) {
        throw const SyncFailure(
          'Refusing to clean a WebDAV recovery file outside the operation storage folder.',
        );
      }
      await webDav.cleanupBackup(
        operation.remoteBackup!,
        operation.id,
        operation.previousRemoteHash,
        cancellation,
      );
    }
    if (forRescan) {
      stateStore.finishRescan(operation.id);
    } else {
      stateStore.finishCleanup(operation.id);
    }
  }

  Future<void> _markRescanIfUntouched(
    PendingOperation operation,
    CancellationToken cancellation,
  ) async {
    if (operation.localDone || operation.remoteDone) return;
    final current = await localStore.hash(operation.path, cancellation);
    final hasPartialCommit =
        operation.expectedLocalHash != null &&
        operation.expectedLocalHash != operation.previousLocalHash &&
        await localStore.canResumeCommit(
          operation.path,
          operation.id,
          operation.expectedLocalHash!,
          operation.previousLocalHash,
          cancellation,
        );
    if (current == operation.previousLocalHash && !hasPartialCommit) {
      stateStore.markNeedsRescan(operation.id);
    }
  }

  String _remoteBackupPath(Directory directory, String id) =>
      '${directory.path}${Platform.pathSeparator}$id.backup';

  String _expectedRemoteBackupPath(String id) =>
      '${File(stateStore.databasePath).parent.path}'
      '${Platform.pathSeparator}sync-v2${Platform.pathSeparator}remote${Platform.pathSeparator}$id.backup';

  String _canonical(String path) {
    final absolute = File(path).absolute.path.replaceAll('/', '\\');
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  String _newOperationId() {
    final random = Random.secure();
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final entropy = List<int>.generate(16, (_) => random.nextInt(256));
    final bytes = <int>[
      ...List<int>.generate(
        8,
        (index) => (int.parse(now, radix: 16) >> (index * 8)) & 0xff,
      ),
      ...entropy,
    ];
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}-a${hex.substring(17, 20)}-${hex.substring(20, 32)}';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
