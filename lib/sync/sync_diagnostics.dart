import 'dart:convert';

/// Opt-in, best-effort tracing. Callers must pass only relative paths, hashes,
/// validators and counters, never credentials, URLs, headers or error messages.
final class SyncDiagnostics {
  static const requested = bool.fromEnvironment('SYNCTUNE_DIAGNOSTICS');
  static void Function(String line)? writer;
  static int _sequence = 0;
  static String? _run;
  static String _phase = 'idle';

  static bool get enabled => writer != null;

  static void recordLazy(String event, Map<String, Object?> Function() fields) {
    if (!enabled) return;
    try {
      record(event, fields());
    } catch (_) {
      // Even reading extra diagnostic counters must be best effort.
    }
  }

  static void beginRun() {
    _run = DateTime.now().microsecondsSinceEpoch.toString();
    _phase = 'preparing';
    record('run_start');
  }

  static void phase(String phase) {
    if (phase == _phase) return;
    _phase = phase;
    record('phase');
  }

  static void endRun(String result) {
    record('run_end', {'result': result});
    _run = null;
    _phase = 'idle';
  }

  static void record(String event, [Map<String, Object?> fields = const {}]) {
    final output = writer;
    if (output == null) return;
    try {
      output(
        jsonEncode({
          ...fields,
          'schema': 1,
          'sequence': ++_sequence,
          'time': DateTime.now().toUtc().toIso8601String(),
          'run': _run,
          'phase': _phase,
          'event': event,
        }),
      );
    } catch (_) {
      // Storage, serialization and transport failures must not affect sync.
    }
  }
}
