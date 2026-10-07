import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/design/theme_mode.dart';

final class _ThemePort implements ThemePreferencePort {
  _ThemePort(this.loaded);

  final ThemeMode loaded;
  ThemeMode? saved;

  @override
  Future<ThemeMode> load() async => loaded;

  @override
  Future<void> save(ThemeMode mode) async => saved = mode;
}

final class _PendingThemePort implements ThemePreferencePort {
  final loaded = Completer<ThemeMode>();

  @override
  Future<ThemeMode> load() => loaded.future;

  @override
  Future<void> save(ThemeMode mode) async {}
}

void main() {
  test(
    'system appearance is the default and persisted appearance is loaded',
    () async {
      final port = _ThemePort(ThemeMode.dark);
      final container = ProviderContainer(
        overrides: [themePreferencePortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), ThemeMode.system);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(themeModeProvider), ThemeMode.dark);

      container.read(themeModeProvider.notifier).select(ThemeMode.light);
      expect(port.saved, ThemeMode.light);
    },
  );

  test(
    'a late preference load cannot overwrite an explicit selection',
    () async {
      final port = _PendingThemePort();
      final container = ProviderContainer(
        overrides: [themePreferencePortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      final model = container.read(themeModeProvider.notifier);

      model.select(ThemeMode.dark);
      port.loaded.complete(ThemeMode.light);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(themeModeProvider), ThemeMode.dark);
    },
  );
}
