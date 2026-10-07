import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../music/music_page.dart';
import '../settings/settings_page.dart';
import '../sync/sync_page.dart';
import '../sync/sync_status_view_model.dart';
import '../design/theme_mode.dart';
import '../design/sync_components.dart';
import '../design/sync_theme.dart';

typedef RootPicker = Future<RootGrant?> Function();
typedef RootRestorer = Future<RootGrant?> Function();
typedef RootRevoker = Future<bool> Function(RootGrant grant);

final class SelectedModuleViewModel extends Notifier<int> {
  @override
  int build() => 0;

  void select(int value) => state = value;
}

final selectedModuleProvider = NotifierProvider<SelectedModuleViewModel, int>(
  SelectedModuleViewModel.new,
);

class SyncTuneShell extends ConsumerStatefulWidget {
  const SyncTuneShell({
    super.key,
    this.onPickRoot,
    this.onRestoreRoot,
    this.onRevokeRoot,
    this.diagnosticsBuilder,
    this.initializationMessage,
  });

  final RootPicker? onPickRoot;
  final RootRestorer? onRestoreRoot;
  final RootRevoker? onRevokeRoot;
  final WidgetBuilder? diagnosticsBuilder;
  final String? initializationMessage;

  static const modules = <({IconData icon, String label})>[
    (icon: Icons.library_music_outlined, label: '音乐'),
    (icon: Icons.sync_outlined, label: '同步'),
    (icon: Icons.settings_outlined, label: '设置'),
  ];

  @override
  ConsumerState<SyncTuneShell> createState() => _SyncTuneShellState();
}

class _SyncTuneShellState extends ConsumerState<SyncTuneShell>
    with WidgetsBindingObserver {
  bool _restoreRootAfterResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final restore = widget.onRestoreRoot;
    if (restore != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(rootGrantProvider.notifier).restore(restore);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_restoreRootAfterResume) {
          _restoreRootAfterResume = false;
          unawaited(_restoreRootAfterPicker());
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _restoreRootAfterResume = true;
        break;
    }
  }

  Future<void> _restoreRootAfterPicker() async {
    final restore = widget.onRestoreRoot;
    if (restore == null) return;
    // Android may recreate the Flutter activity while the system document
    // picker is open. Native grant validation is serialized on a worker, so
    // re-read the saved grant briefly after resume to cover that handoff.
    for (final delay in const <Duration>[
      Duration(milliseconds: 250),
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(milliseconds: 1500),
    ]) {
      await Future<void>.delayed(delay);
      if (!mounted) return;
      await ref.read(rootGrantProvider.notifier).restore(restore);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedModuleProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'SyncTune',
      theme: syncTuneLightTheme(),
      darkTheme: syncTuneDarkTheme(),
      themeMode: themeMode,
      builder: (context, child) => MediaQuery(
        // Keep system scaling intact; pages scroll so 200% text stays usable.
        data: MediaQuery.of(context),
        child: child ?? const SizedBox.shrink(),
      ),
      home: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 600;
          final wide = constraints.maxWidth >= 1000;
          final content = _ModulePage(
            module: selected,
            expandedLayout: wide,
            onPickRoot: widget.onPickRoot,
            onRevokeRoot: widget.onRevokeRoot,
            diagnosticsBuilder: widget.diagnosticsBuilder,
          );
          if (compact) {
            return Scaffold(
              body: _withInitializationMessage(content),
              bottomNavigationBar: NavigationBar(
                selectedIndex: selected,
                onDestinationSelected: _select,
                destinations: [
                  for (final item in SyncTuneShell.modules)
                    NavigationDestination(
                      icon: Icon(item.icon),
                      label: item.label,
                    ),
                ],
              ),
            );
          }
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  extended: wide,
                  selectedIndex: selected,
                  onDestinationSelected: _select,
                  destinations: [
                    for (final item in SyncTuneShell.modules)
                      NavigationRailDestination(
                        icon: Icon(item.icon),
                        label: Text(item.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _withInitializationMessage(content)),
              ],
            ),
          );
        },
      ),
    );
  }

  void _select(int value) =>
      ref.read(selectedModuleProvider.notifier).select(value);

  Widget _withInitializationMessage(Widget content) {
    final message = widget.initializationMessage;
    if (message == null || message.trim().isEmpty) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SyncTuneTokens.space16,
            SyncTuneTokens.space12,
            SyncTuneTokens.space16,
            0,
          ),
          child: SyncTuneStatusCard(
            title: '本地服务初始化未完成',
            message: message,
            icon: Icons.warning_amber_outlined,
            tone: SyncTuneStatusTone.warning,
          ),
        ),
        Expanded(child: content),
      ],
    );
  }
}

class _ModulePage extends StatelessWidget {
  const _ModulePage({
    required this.module,
    required this.expandedLayout,
    required this.onPickRoot,
    required this.onRevokeRoot,
    required this.diagnosticsBuilder,
  });

  final int module;
  final bool expandedLayout;
  final RootPicker? onPickRoot;
  final RootRevoker? onRevokeRoot;
  final WidgetBuilder? diagnosticsBuilder;

  @override
  Widget build(BuildContext context) => switch (module) {
    0 => MusicPage(expandedLayout: expandedLayout),
    1 => const SyncPage(),
    _ => SettingsPage(
      onPickRoot: onPickRoot,
      onRevokeRoot: onRevokeRoot,
      diagnosticsBuilder: diagnosticsBuilder,
    ),
  };
}
