import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sync_engine.dart';
import 'sync_model.dart';
import 'sync_platform.dart';

/// The only UI-facing synchronization state. Screens listen to this controller
/// and pass a fresh configuration to [start].
final class SyncController extends ChangeNotifier {
  SyncController({
    required this.engine,
    required this.credentials,
    required this.executionHost,
  });

  final SyncEngine engine;
  final SyncCredentialStore credentials;
  final SyncExecutionHost executionHost;

  SyncProgress _progress = const SyncProgress();
  SyncProgress get progress => _progress;
  bool get isRunning => _cancellation != null;

  CancellationToken? _cancellation;
  Completer<void>? _activeCompletion;
  bool _disposed = false;
  bool _configurationWriteInProgress = false;

  Future<void> start(SyncSettings settings) async {
    if (_cancellation != null)
      throw const SyncFailure('A synchronization is already running.');
    if (_configurationWriteInProgress) {
      throw const SyncFailure(
        'Settings are being saved. Try again when saving is complete.',
      );
    }
    final cancellation = CancellationToken();
    _cancellation = cancellation;
    final completion = Completer<void>();
    _activeCompletion = completion;
    _publish(const SyncProgress(phase: SyncPhase.recovering));
    var hostStarted = false;
    try {
      final secret = await credentials.read(settings);
      cancellation.throwIfCancelled();
      await executionHost.start(settings);
      hostStarted = true;
      await engine.run(
        settings,
        secret: secret,
        cancellation: cancellation,
        onProgress: (next) async {
          _publish(next);
          await executionHost.update(next);
        },
      );
    } on SyncCancelled {
      _publish(
        _progress.copyWith(
          phase: SyncPhase.cancelled,
          currentFile: '',
          error: 'Synchronization was cancelled.',
        ),
      );
    } catch (error) {
      _publish(
        _progress.copyWith(
          phase: SyncPhase.failed,
          currentFile: '',
          error: error.toString(),
        ),
      );
    } finally {
      if (hostStarted) {
        try {
          await executionHost.finish(_progress);
        } catch (error) {
          if (_progress.phase == SyncPhase.complete) {
            _publish(
              _progress.copyWith(
                phase: SyncPhase.failed,
                error:
                    'Synchronization completed, but the platform could not update its status: $error',
              ),
            );
          } else if (_progress.error.isEmpty) {
            _publish(
              _progress.copyWith(
                error: 'The platform could not update its status: $error',
              ),
            );
          }
        }
      }
      _cancellation = null;
      if (identical(_activeCompletion, completion)) _activeCompletion = null;
      if (!_disposed) notifyListeners();
      if (!completion.isCompleted) completion.complete();
    }
  }

  void cancel() {
    _cancellation?.cancel();
  }

  bool get configurationWriteInProgress => _configurationWriteInProgress;

  bool beginConfigurationWrite() {
    if (isRunning || _configurationWriteInProgress) return false;
    _configurationWriteInProgress = true;
    notifyListeners();
    return true;
  }

  void endConfigurationWrite() {
    if (!_configurationWriteInProgress) return;
    _configurationWriteInProgress = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> cancelAndWait() async {
    final completion = _activeCompletion;
    if (completion == null) return;
    cancel();
    await completion.future;
  }

  void _publish(SyncProgress next) {
    _progress = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancellation?.cancel();
    super.dispose();
  }
}
