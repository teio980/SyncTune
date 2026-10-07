import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Storage is supplied by the composition root. The UI defaults to system
/// appearance and does not claim persistence when this port is unavailable.
abstract interface class ThemePreferencePort {
  Future<ThemeMode> load();

  Future<void> save(ThemeMode mode);
}

final themePreferencePortProvider = Provider<ThemePreferencePort?>(
  (ref) => null,
);

final class ThemeModeViewModel extends Notifier<ThemeMode> {
  int _request = 0;
  bool _disposed = false;

  @override
  ThemeMode build() {
    ref.onDispose(() => _disposed = true);
    final port = ref.read(themePreferencePortProvider);
    if (port != null) _load(port);
    return ThemeMode.system;
  }

  Future<void> _load(ThemePreferencePort port) async {
    final request = ++_request;
    try {
      final mode = await port.load();
      if (_disposed || request != _request) return;
      state = mode;
    } catch (_) {
      // System appearance remains the safe default when preference storage is
      // unavailable or contains an invalid value.
    }
  }

  void select(ThemeMode mode) {
    final request = ++_request;
    if (_disposed) return;
    state = mode;
    final port = ref.read(themePreferencePortProvider);
    if (port != null) _save(port, mode, request);
  }

  Future<void> _save(
    ThemePreferencePort port,
    ThemeMode mode,
    int request,
  ) async {
    try {
      await port.save(mode);
      if (_disposed || request != _request) return;
    } catch (_) {
      // The selected mode still applies for this run; the next startup will
      // fall back to system if persistence remains unavailable.
    }
  }
}

final themeModeProvider = NotifierProvider<ThemeModeViewModel, ThemeMode>(
  ThemeModeViewModel.new,
);
