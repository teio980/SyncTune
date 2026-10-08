import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../platform/sync_platform_adapters.dart';
import '../sync/state_store.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_model.dart';
import '../sync/sync_platform.dart';
import 'localization/strings.dart';

final class SyncAppConfig {
  const SyncAppConfig({required this.language, this.settings});
  final String language;
  final SyncSettings? settings;

  SyncAppConfig copyWith({String? language, SyncSettings? settings}) =>
      SyncAppConfig(
        language: language ?? this.language,
        settings: settings ?? this.settings,
      );

  static SyncAppConfig fromStore(Map<String, String> values) {
    final localRoot = values['local_root'] ?? '';
    final serverUrl = values['server_url'] ?? '';
    final localRootId = values['local_root_id'] ?? '';
    final localGeneration = values['local_generation'] ?? '';
    final username = values['username'] ?? '';
    final ready =
        localRoot.isNotEmpty &&
        localRootId.isNotEmpty &&
        serverUrl.isNotEmpty &&
        username.isNotEmpty;
    return SyncAppConfig(
      language: values['language'] == 'zh' ? 'zh' : 'en',
      settings: ready
          ? SyncSettings(
              localRoot: localRoot,
              localRootId: localRootId,
              localGeneration: localGeneration,
              serverUrl: serverUrl,
              remoteRoot: values['remote_root'] ?? '',
              username: username,
              language: values['language'] ?? 'en',
            )
          : null,
    );
  }

  Map<String, String> settingsValues(SyncSettings settings) => <String, String>{
    'local_root': settings.localRoot,
    'local_root_id': settings.localRootId,
    'local_generation': settings.localGeneration,
    'server_url': settings.serverUrl,
    'remote_root': settings.remoteRoot,
    'username': settings.username,
    'language': language,
    'sync_identity': settings.syncIdentity,
  };
}

final class SyncTuneApp extends StatelessWidget {
  const SyncTuneApp({
    required this.config,
    required this.stateStore,
    required this.platform,
    required this.controller,
    super.key,
  });

  final ValueNotifier<SyncAppConfig> config;
  final SqliteStateStore stateStore;
  final SyncPlatformAdapters platform;
  final SyncController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SyncAppConfig>(
    valueListenable: config,
    builder: (context, value, _) => MaterialApp(
      title: 'SyncTune',
      debugShowCheckedModeBanner: false,
      locale: Locale(value.language),
      supportedLocales: SyncTuneStrings.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        SyncTuneStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF225E62)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF69C5C1),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: _SyncTuneShell(
        config: config,
        stateStore: stateStore,
        platform: platform,
        controller: controller,
      ),
    ),
  );
}

final class _SyncTuneShell extends StatefulWidget {
  const _SyncTuneShell({
    required this.config,
    required this.stateStore,
    required this.platform,
    required this.controller,
  });
  final ValueNotifier<SyncAppConfig> config;
  final SqliteStateStore stateStore;
  final SyncPlatformAdapters platform;
  final SyncController controller;

  @override
  State<_SyncTuneShell> createState() => _SyncTuneShellState();
}

final class _SyncTuneShellState extends State<_SyncTuneShell> {
  int _page = 0;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const LocalizedText('SyncTune')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _page == 0
                  ? _SyncHome(
                      config: widget.config,
                      controller: widget.controller,
                      onSettings: () => setState(() => _page = 1),
                    )
                  : _SettingsPage(
                      config: widget.config,
                      stateStore: widget.stateStore,
                      platform: widget.platform,
                      controller: widget.controller,
                      onDone: () => setState(() => _page = 0),
                    ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        onDestinationSelected: widget.controller.configurationWriteInProgress
            ? null
            : (index) => setState(() => _page = index),
        destinations: <NavigationDestination>[
          NavigationDestination(
            icon: const Icon(Icons.sync),
            label: SyncTuneStrings.of(context).text('Sync'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings),
            label: SyncTuneStrings.of(context).text('Settings'),
          ),
        ],
      ),
    ),
  );
}

final class _SyncHome extends StatelessWidget {
  const _SyncHome({
    required this.config,
    required this.controller,
    required this.onSettings,
  });
  final ValueListenable<SyncAppConfig> config;
  final SyncController controller;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SyncAppConfig>(
    valueListenable: config,
    builder: (context, saved, _) {
      final settings = saved.settings;
      final progress = controller.progress;
      final running = controller.isRunning;
      final status = switch (progress.phase) {
        SyncPhase.idle => 'Ready',
        SyncPhase.recovering => 'Recovering previous work',
        SyncPhase.scanning => 'Scanning files',
        SyncPhase.comparing => 'Comparing files',
        SyncPhase.transferring => 'Transferring files',
        SyncPhase.verifying => 'Verifying both folders',
        SyncPhase.saving => 'Saving sync state',
        SyncPhase.complete => 'Sync complete',
        SyncPhase.cancelled => 'Sync cancelled',
        SyncPhase.failed => 'Sync failed',
      };
      return ListView(
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const LocalizedText(
                    'Sync',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  _SideInfo(
                    label: 'Local folder',
                    value:
                        settings?.localRoot ??
                        SyncTuneStrings.of(context).text('No folder selected'),
                  ),
                  const SizedBox(height: 12),
                  _SideInfo(
                    label: 'WebDAV folder',
                    value: settings == null
                        ? 'No folder selected'
                        : _remoteLabel(settings),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    SyncTuneStrings.of(context).text(status),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (progress.fraction != null) ...<Widget>[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: progress.fraction),
                  ] else if (running) ...<Widget>[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  if (progress.currentFile.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    SelectableText(progress.currentFile),
                  ],
                  if (running || progress.filesDone > 0) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      '${SyncTuneStrings.of(context).text('Files')}: '
                      '${progress.filesDone} / ${progress.fileCount}',
                    ),
                    Text(
                      '${SyncTuneStrings.of(context).text('Data')}: '
                      '${_formatBytes(progress.bytesDone)} / ${_formatBytes(progress.totalBytes)}',
                    ),
                  ],
                  if (progress.error.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    SelectableText(
                      progress.error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed:
                            running ||
                                settings == null ||
                                controller.configurationWriteInProgress
                            ? null
                            : () => controller.start(settings),
                        icon: const Icon(Icons.play_arrow),
                        label: const LocalizedText('Start sync'),
                      ),
                      OutlinedButton.icon(
                        onPressed: running ? controller.cancel : onSettings,
                        icon: Icon(
                          running ? Icons.cancel_outlined : Icons.settings,
                        ),
                        label: LocalizedText(
                          running ? 'Cancel sync' : 'Open settings',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LocalizedText(
              'Files are matched by relative folder and filename. Sync starts only when you press Start.',
            ),
          ),
        ],
      );
    },
  );
}

final class _SideInfo extends StatelessWidget {
  const _SideInfo({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        SyncTuneStrings.of(context).text(label),
        style: Theme.of(context).textTheme.labelLarge,
      ),
      const SizedBox(height: 4),
      SelectableText(value),
    ],
  );
}

final class _SettingsPage extends StatefulWidget {
  const _SettingsPage({
    required this.config,
    required this.stateStore,
    required this.platform,
    required this.controller,
    required this.onDone,
  });
  final ValueNotifier<SyncAppConfig> config;
  final SqliteStateStore stateStore;
  final SyncPlatformAdapters platform;
  final SyncController controller;
  final VoidCallback onDone;
  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<_SettingsPage> {
  late final TextEditingController _server;
  late final TextEditingController _remote;
  late final TextEditingController _username;
  late final TextEditingController _password;
  SyncFolderSelection? _folder;
  late String _language;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final current = widget.config.value;
    final settings = current.settings;
    _server = TextEditingController(text: settings?.serverUrl ?? '');
    _remote = TextEditingController(text: settings?.remoteRoot ?? '');
    _username = TextEditingController(text: settings?.username ?? '');
    _password = TextEditingController();
    if (settings != null) {
      _folder = SyncFolderSelection(
        locator: settings.localRoot,
        stableId: settings.localRootId,
        generation: settings.localGeneration,
      );
    }
    _language = current.language;
  }

  @override
  void dispose() {
    _server.dispose();
    _remote.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    if (_busy || widget.controller.isRunning) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final selected = await widget.platform.pick();
      if (!mounted) return;
      if (selected != null) setState(() => _folder = selected);
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || !widget.controller.beginConfigurationWrite()) return;
    final strings = SyncTuneStrings.of(context);
    final folder = _folder;
    if (folder == null) {
      widget.controller.endConfigurationWrite();
      setState(
        () => _message = strings.text(
          'Choose a local music folder before saving.',
        ),
      );
      return;
    }
    final server = Uri.tryParse(_server.text.trim());
    if (server == null ||
        server.scheme != 'https' ||
        !server.hasAuthority ||
        server.host.isEmpty ||
        server.userInfo.isNotEmpty ||
        server.hasQuery ||
        server.hasFragment) {
      widget.controller.endConfigurationWrite();
      setState(() => _message = strings.text('Enter an HTTPS WebDAV URL.'));
      return;
    }
    final username = _username.text.trim();
    if (username.isEmpty) {
      widget.controller.endConfigurationWrite();
      setState(() => _message = strings.text('Enter the WebDAV username.'));
      return;
    }
    final old = widget.config.value.settings;
    final candidate = SyncSettings(
      localRoot: folder.locator,
      localRootId: folder.stableId,
      localGeneration: folder.generation,
      serverUrl: _server.text.trim(),
      remoteRoot: _remote.text.trim(),
      username: username,
      language: _language,
    );
    final identityChanged = old?.syncIdentity != candidate.syncIdentity;
    if (identityChanged && widget.stateStore.loadPending().isNotEmpty) {
      widget.controller.endConfigurationWrite();
      setState(
        () => _message = strings.text(
          'The previous sync must recover before changing the folder or account.',
        ),
      );
      return;
    }
    if (identityChanged && _password.text.isEmpty) {
      widget.controller.endConfigurationWrite();
      setState(() => _message = strings.text('Enter the WebDAV password.'));
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (_password.text.isNotEmpty)
        await widget.platform.write(candidate, _password.text);
      if (widget.controller.isRunning) {
        throw const SyncFailure(
          'Synchronization started while settings were being saved.',
        );
      }
      widget.stateStore.saveSettings(
        SyncAppConfig(language: candidate.language).settingsValues(candidate),
        identityChanged: identityChanged,
      );
      if (identityChanged && old != null) {
        try {
          await widget.platform.commitFolder(
            old.localRoot,
            candidate.localRoot,
          );
        } catch (_) {
          // Keep the saved settings usable even if a stale SAF grant cannot be released.
        }
      }
      if (identityChanged && old != null) {
        try {
          await widget.platform.delete(old);
        } catch (_) {
          // The active credential and saved settings are already consistent.
        }
      }
      widget.config.value = SyncAppConfig(
        language: _language,
        settings: candidate,
      );
      if (mounted) setState(() => _message = strings.text('Saved'));
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      widget.controller.endConfigurationWrite();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    children: <Widget>[
      Text(
        SyncTuneStrings.of(context).text('Settings'),
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: _busy || widget.controller.isRunning ? null : _pickFolder,
        icon: const Icon(Icons.folder_open),
        label: const LocalizedText('Choose music folder'),
      ),
      const SizedBox(height: 6),
      SelectableText(
        _folder?.locator ??
            SyncTuneStrings.of(context).text('No folder selected'),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _server,
        enabled: !_busy && !widget.controller.isRunning,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: SyncTuneStrings.of(context).text('Server URL'),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _remote,
        enabled: !_busy && !widget.controller.isRunning,
        decoration: InputDecoration(
          labelText: SyncTuneStrings.of(context).text('Remote folder'),
          helperText: SyncTuneStrings.of(context).text(
            'Enter a relative WebDAV directory, or leave it blank for the URL folder.',
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _username,
        enabled: !_busy && !widget.controller.isRunning,
        decoration: InputDecoration(
          labelText: SyncTuneStrings.of(context).text('Username'),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        enabled: !_busy && !widget.controller.isRunning,
        obscureText: true,
        decoration: InputDecoration(
          labelText: SyncTuneStrings.of(context).text('Password'),
          helperText: SyncTuneStrings.of(context).text(
            'Changes apply after Save. The password is held in the system credential store.',
          ),
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _language,
        decoration: InputDecoration(
          labelText: SyncTuneStrings.of(context).text('Language'),
        ),
        items: <DropdownMenuItem<String>>[
          DropdownMenuItem(
            value: 'en',
            child: Text(SyncTuneStrings.of(context).text('English')),
          ),
          const DropdownMenuItem(value: 'zh', child: Text('简体中文')),
        ],
        onChanged: _busy || widget.controller.isRunning
            ? null
            : (value) {
                if (value != null) setState(() => _language = value);
              },
      ),
      if (widget.controller.isRunning) ...<Widget>[
        const SizedBox(height: 12),
        const LocalizedText(
          'Settings cannot change while synchronization is running.',
        ),
      ],
      if (_message != null) ...<Widget>[
        const SizedBox(height: 12),
        SelectableText(_message!),
      ],
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _busy || widget.controller.isRunning ? null : _save,
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save),
        label: LocalizedText(_busy ? 'Saving…' : 'Save settings'),
      ),
    ],
  );
}

String _remoteLabel(SyncSettings settings) => settings.remoteRoot.isEmpty
    ? settings.serverUrl
    : '${settings.serverUrl}/${settings.remoteRoot}';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  return '${value.toStringAsFixed(1)} ${units[index]}';
}
