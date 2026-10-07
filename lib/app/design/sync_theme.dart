import 'package:flutter/material.dart';

const syncTuneSeed = Color(0xFF4F46E5);

/// Shared layout and shape values used by every SyncTune module.
abstract final class SyncTuneTokens {
  static const space4 = 4.0;
  static const space8 = 8.0;
  static const space12 = 12.0;
  static const space16 = 16.0;
  static const space24 = 24.0;
  static const space32 = 32.0;

  static const radius8 = 8.0;
  static const radius12 = 12.0;

  static const contentMaxWidth = 1280.0;
  static const minInteractiveSize = 48.0;
}

ThemeData syncTuneLightTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: syncTuneSeed),
  visualDensity: VisualDensity.standard,
  materialTapTargetSize: MaterialTapTargetSize.padded,
  filledButtonTheme: FilledButtonThemeData(style: _buttonTouchStyle()),
  outlinedButtonTheme: OutlinedButtonThemeData(style: _buttonTouchStyle()),
  textButtonTheme: TextButtonThemeData(style: _buttonTouchStyle()),
  iconButtonTheme: IconButtonThemeData(style: _iconButtonTouchStyle()),
  inputDecorationTheme: const InputDecorationTheme(
    border: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(SyncTuneTokens.radius8)),
    ),
  ),
  cardTheme: const CardThemeData(
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(SyncTuneTokens.radius12)),
    ),
  ),
);

ThemeData syncTuneDarkTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: syncTuneSeed,
    brightness: Brightness.dark,
  ),
  visualDensity: VisualDensity.standard,
  materialTapTargetSize: MaterialTapTargetSize.padded,
  filledButtonTheme: FilledButtonThemeData(style: _buttonTouchStyle()),
  outlinedButtonTheme: OutlinedButtonThemeData(style: _buttonTouchStyle()),
  textButtonTheme: TextButtonThemeData(style: _buttonTouchStyle()),
  iconButtonTheme: IconButtonThemeData(style: _iconButtonTouchStyle()),
  inputDecorationTheme: const InputDecorationTheme(
    border: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(SyncTuneTokens.radius8)),
    ),
  ),
  cardTheme: const CardThemeData(
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(SyncTuneTokens.radius12)),
    ),
  ),
);

ButtonStyle _buttonTouchStyle() => const ButtonStyle(
  minimumSize: WidgetStatePropertyAll(
    Size(0, SyncTuneTokens.minInteractiveSize),
  ),
  tapTargetSize: MaterialTapTargetSize.padded,
);

ButtonStyle _iconButtonTouchStyle() => const ButtonStyle(
  minimumSize: WidgetStatePropertyAll(
    Size.square(SyncTuneTokens.minInteractiveSize),
  ),
  tapTargetSize: MaterialTapTargetSize.padded,
);
