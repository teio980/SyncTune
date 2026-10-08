import 'dart:async';

import 'package:flutter/foundation.dart';
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
    'language': settings.language,
    'sync_identity': settings.syncIdentity,
  };
}

final class SyncTuneApp extends StatelessWidget {
  const SyncTuneApp({
    required this.config,
    required this.stateStore,
    required this.platform,
    required this.controller,
    required this.musicLibrary,
    super.key,
  });

  final ValueNotifier<SyncAppConfig> config;
  final SqliteStateStore stateStore;
  final SyncPlatformAdapters platform;
  final SyncController controller;
  final SyncMusicLibrary musicLibrary;

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
        musicLibrary: musicLibrary,
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
    required this.musicLibrary,
  });
  final ValueNotifier<SyncAppConfig> config;
  final SqliteStateStore stateStore;
  final SyncPlatformAdapters platform;
  final SyncController controller;
  final SyncMusicLibrary musicLibrary;

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
                  ? _MusicPage(
                      config: widget.config,
                      musicLibrary: widget.musicLibrary,
                      controller: widget.controller,
                      stateStore: widget.stateStore,
                    )
                  : _page == 1
                  ? _SyncHome(
                      config: widget.config,
                      controller: widget.controller,
                      onSettings: () => setState(() => _page = 2),
                    )
                  : _SettingsPage(
                      config: widget.config,
                      stateStore: widget.stateStore,
                      platform: widget.platform,
                      controller: widget.controller,
                      onDone: () => setState(() => _page = 1),
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
            icon: const Icon(Icons.library_music),
            label: SyncTuneStrings.of(context).text('Music'),
          ),
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

final class _MusicPage extends StatefulWidget {
  const _MusicPage({
    required this.config,
    required this.musicLibrary,
    required this.controller,
    required this.stateStore,
  });
  final ValueListenable<SyncAppConfig> config;
  final SyncMusicLibrary musicLibrary;
  final SyncController controller;
  final SqliteStateStore stateStore;

  @override
  State<_MusicPage> createState() => _MusicPageState();
}

final class _MusicPageState extends State<_MusicPage> {
  List<SyncMusicTrack> _tracks = const <SyncMusicTrack>[];
  final Set<String> _selected = <String>{};
  bool _loading = false;
  bool _deleting = false;
  String _loadedIdentity = '';
  String? _message;

  @override
  void initState() {
    super.initState();
    widget.config.addListener(_configurationChanged);
    _refresh();
  }

  @override
  void dispose() {
    widget.config.removeListener(_configurationChanged);
    super.dispose();
  }

  void _configurationChanged() {
    final identity = widget.config.value.settings?.syncIdentity ?? '';
    if (identity != _loadedIdentity && mounted) _refresh();
  }

  Future<void> _refresh() async {
    final settings = widget.config.value.settings;
    if (settings == null) {
      setState(() {
        _tracks = const <SyncMusicTrack>[];
        _selected.clear();
        _loadedIdentity = '';
        _message = null;
      });
      return;
    }
    if (_loading || _deleting) return;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final tracks = await widget.musicLibrary.listMusic(settings);
      if (!mounted ||
          widget.config.value.settings?.syncIdentity != settings.syncIdentity) {
        return;
      }
      setState(() {
        _tracks = tracks;
        _selected.clear();
        _loadedIdentity = settings.syncIdentity;
      });
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteSelected({SyncMusicTrack? only}) async {
    final settings = widget.config.value.settings;
    if (settings == null || _deleting || widget.controller.isRunning) return;
    final pending = widget.stateStore.loadPending();
    if (pending.isNotEmpty) {
      setState(
        () =>
            _message = SyncTuneStrings.of(context)
                .text('Recover the previous sync before deleting music.'),
      );
      return;
    }
    final targets = only == null
        ? _tracks.where((item) => _selected.contains(item.path.value)).toList()
        : <SyncMusicTrack>[only];
    if (targets.isEmpty) return;
    final strings = SyncTuneStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.text('Delete music?')),
        content: Text(
          '${strings.text('This removes the selected files from this device. The next sync will propagate deletion for songs already in the sync history. Songs not yet registered from WebDAV may download again on the first sync.')}'
          '\n\n${targets.take(3).map((item) => item.path.value).join('\n')}'
          '${targets.length > 3 ? '\n…' : ''}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.text('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.text('Delete locally')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (widget.config.value.settings?.syncIdentity != settings.syncIdentity) {
      setState(
        () => _message = strings.text(
          'The selected folder changed; refresh the list.',
        ),
      );
      return;
    }
    if (!widget.controller.beginExclusiveOperation()) return;
    setState(() {
      _deleting = true;
      _message = null;
    });
    try {
      if (widget.stateStore.loadPending().isNotEmpty) {
        throw const SyncFailure(
          'Recover the previous sync before deleting music.',
        );
      }
      final deleted = <String>{};
      final errors = <String>[];
      for (final track in targets) {
        try {
          await widget.musicLibrary.deleteMusic(settings, track);
          deleted.add(track.path.value);
        } catch (error) {
          errors.add('${track.path.value}: $error');
        }
      }
      if (mounted) {
        setState(() {
          _tracks = _tracks
              .where((item) => !deleted.contains(item.path.value))
              .toList();
          _selected.clear();
          _message = errors.isEmpty
              ? strings.text(
                  'Deleted locally. The next sync will compare both folders.',
                )
              : errors.join('\n');
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      widget.controller.endExclusiveOperation();
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SyncAppConfig>(
    valueListenable: widget.config,
    builder: (context, saved, _) {
      final settings = saved.settings;
      final blocked =
          settings == null ||
          _loading ||
          _deleting ||
          widget.controller.isRunning ||
          widget.controller.configurationWriteInProgress;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  SyncTuneStrings.of(context).text('Music'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                tooltip: SyncTuneStrings.of(context).text('Refresh'),
                onPressed: settings == null || _loading || _deleting
                    ? null
                    : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (settings == null)
            const Expanded(
              child: Center(
                child: LocalizedText(
                  'Choose a local music folder in Settings.',
                ),
              ),
            )
          else ...<Widget>[
            SelectableText(settings.localRoot, maxLines: 2),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${_tracks.length} ${SyncTuneStrings.of(context).text('songs')}',
                  ),
                ),
                TextButton.icon(
                  onPressed: blocked || _selected.isEmpty
                      ? null
                      : () => _deleteSelected(),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(
                    '${SyncTuneStrings.of(context).text('Delete locally')} (${_selected.length})',
                  ),
                ),
              ],
            ),
            if (_loading || _deleting) const LinearProgressIndicator(),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(_message!),
              ),
            Expanded(
              child: _tracks.isEmpty && !_loading
                  ? Center(
                      child: Text(
                        SyncTuneStrings.of(context)
                            .text('No music files found.'),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _tracks.length,
                      itemBuilder: (context, index) {
                        final track = _tracks[index];
                        final selected = _selected.contains(track.path.value);
                        return ListTile(
                          dense: true,
                          leading: Checkbox(
                            value: selected,
                            onChanged: blocked
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(track.path.value);
                                    } else {
                                      _selected.remove(track.path.value);
                                    }
                                  }),
                          ),
                          title: Text(
                            track.path.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            track.path.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: SyncTuneStrings.of(context)
                                .text('Delete locally'),
                            onPressed: blocked
                                ? null
                                : () => _deleteSelected(only: track),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        );
                      },
                    ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LocalizedText(
                'Music is listed from the selected folder. Deleting here removes only the chosen local song files.',
              ),
            ),
          ],
        ],
      );
    },
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
                    label: 'WebDAV URL',
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
  late final TextEditingController _username;
  late final TextEditingController _password;
  SyncFolderSelection? _folder;
  late String _language;
  bool _busy = false;
  bool _passwordVisible = false;
  bool _revealedSavedPassword = false;
  bool _editedRevealedPassword = false;
  String? _savedCredentialAccount;
  String? _inputAccountKey;
  int _passwordRevealRequest = 0;
  CancellationToken? _testCancellation;
  String? _message;

  @override
  void initState() {
    super.initState();
    final current = widget.config.value;
    final settings = current.settings;
    _server = TextEditingController(
      text: settings == null ? '' : _effectiveRemoteUrl(settings),
    );
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
    if (settings != null) {
      _inputAccountKey = _accountKey(settings);
      unawaited(_refreshPasswordStatus(settings));
    }
  }

  @override
  void dispose() {
    _testCancellation?.cancel();
    _server.dispose();
    _username.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _refreshPasswordStatus(SyncSettings settings) async {
    try {
      final saved = await widget.platform.hasSavedCredential(settings);
      if (mounted &&
          widget.config.value.settings?.syncIdentity == settings.syncIdentity) {
        setState(
          () => _savedCredentialAccount = saved ? _accountKey(settings) : null,
        );
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    }
  }

  bool _sameSavedAccount(SyncSettings settings) {
    final current = widget.config.value.settings;
    return current != null && _accountKey(current) == _accountKey(settings);
  }

  SyncSettings _candidate({bool requireFolder = false}) {
    final entered = _server.text.trim();
    final server = Uri.tryParse(entered);
    if (server == null ||
        server.scheme != 'https' ||
        !server.hasAuthority ||
        server.host.isEmpty ||
        server.userInfo.isNotEmpty ||
        server.hasQuery ||
        server.hasFragment) {
      throw const SyncFailure('Enter an HTTPS WebDAV URL.');
    }
    final username = _username.text.trim();
    if (username.isEmpty) throw const SyncFailure('Enter the WebDAV username.');
    final folder = _folder;
    if (requireFolder && folder == null) {
      throw const SyncFailure('Choose a local music folder before saving.');
    }
    final old = widget.config.value.settings;
    final sameTarget =
        old != null &&
        _canonicalUrl(_effectiveRemoteUrl(old)) == _canonicalUrl(entered);
    return SyncSettings(
      localRoot: folder?.locator ?? old?.localRoot ?? '',
      localRootId: folder?.stableId ?? old?.localRootId ?? '',
      localGeneration: folder?.generation ?? old?.localGeneration ?? '',
      serverUrl: sameTarget ? old.serverUrl : entered,
      remoteRoot: sameTarget ? old.remoteRoot : '',
      username: username,
      language: _language,
    );
  }

  Future<String> _secretFor(SyncSettings candidate) async {
    if (_password.text.isNotEmpty) return _password.text;
    if (await widget.platform.hasSavedCredential(candidate)) {
      return widget.platform.read(candidate);
    }
    final current = widget.config.value.settings;
    if (current != null && _sameSavedAccount(candidate)) {
      return widget.platform.read(current);
    }
    throw const SyncFailure(
      'Enter a password or use an account with a saved password.',
    );
  }

  Future<void> _testConnection() async {
    if (_busy || widget.controller.isRunning) return;
    late final SyncSettings candidate;
    try {
      candidate = _candidate();
    } catch (error) {
      setState(
        () => _message = SyncTuneStrings.of(context).text(error.toString()),
      );
      return;
    }
    final cancellation = CancellationToken();
    setState(() {
      _busy = true;
      _message = null;
      _testCancellation = cancellation;
    });
    try {
      await widget.controller.testConnection(
        candidate,
        secret: () => _secretFor(candidate),
        cancellation: cancellation,
      );
      if (mounted) {
        setState(
          () =>
              _message = SyncTuneStrings.of(context)
                  .text('WebDAV connection successful.'),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      _testCancellation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePassword() async {
    if (_busy) return;
    if (_passwordVisible) {
      if (_revealedSavedPassword && !_editedRevealedPassword) _password.clear();
      setState(() {
        _passwordVisible = false;
        _revealedSavedPassword = false;
        _editedRevealedPassword = false;
      });
      return;
    }
    if (_password.text.isEmpty) {
      late final SyncSettings candidate;
      try {
        candidate = _candidate();
      } catch (error) {
        if (mounted) setState(() => _message = error.toString());
        return;
      }
      final account = _accountKey(candidate);
      final request = ++_passwordRevealRequest;
      try {
        final value = await _secretFor(candidate);
        if (!mounted || request != _passwordRevealRequest) return;
        late final String currentAccount;
        try {
          currentAccount = _accountKey(_candidate());
        } catch (_) {
          return;
        }
        if (currentAccount != account) return;
        _password.text = value;
        _revealedSavedPassword = true;
        _editedRevealedPassword = false;
      } catch (error) {
        if (mounted) setState(() => _message = error.toString());
        return;
      }
    }
    if (mounted) setState(() => _passwordVisible = true);
  }

  bool get _savedCredentialUsable {
    try {
      return _savedCredentialAccount != null &&
          _savedCredentialAccount == _accountKey(_candidate());
    } catch (_) {
      return false;
    }
  }

  void _credentialFieldsChanged() {
    String? nextAccount;
    try {
      nextAccount = _accountKey(_candidate());
    } catch (_) {
      nextAccount = null;
    }
    if (nextAccount == _inputAccountKey) {
      setState(() {});
      return;
    }
    _inputAccountKey = nextAccount;
    _passwordRevealRequest++;
    final current = widget.config.value.settings;
    final sameAccount =
        current != null &&
        nextAccount != null &&
        _accountKey(current) == nextAccount;
    if (!sameAccount) {
      if (_revealedSavedPassword && !_editedRevealedPassword) _password.clear();
      _revealedSavedPassword = false;
      _editedRevealedPassword = false;
    } else {
      unawaited(_refreshPasswordStatus(current));
    }
    setState(() {});
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
    late final SyncSettings candidate;
    try {
      candidate = _candidate(requireFolder: true);
    } catch (error) {
      widget.controller.endConfigurationWrite();
      setState(() => _message = strings.text(error.toString()));
      return;
    }
    final old = widget.config.value.settings;
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
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      var secret = '';
      if (_password.text.isNotEmpty) {
        secret = _password.text;
      } else if (await widget.platform.hasSavedCredential(candidate)) {
        secret = await widget.platform.read(candidate);
      } else if (old != null && _sameSavedAccount(candidate)) {
        secret = await widget.platform.read(old);
      }
      if (identityChanged && secret.isEmpty) {
        throw const SyncFailure('Enter the WebDAV password.');
      }
      if (secret.isNotEmpty && (identityChanged || _password.text.isNotEmpty)) {
        await widget.platform.write(candidate, secret);
      }
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
      _password.clear();
      _passwordVisible = false;
      _revealedSavedPassword = false;
      _editedRevealedPassword = false;
      _savedCredentialAccount = secret.isNotEmpty
          ? _accountKey(candidate)
          : null;
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
        enabled:
            !_busy &&
            !widget.controller.isRunning &&
            !widget.controller.configurationWriteInProgress,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: SyncTuneStrings.of(context).text('WebDAV URL'),
          helperText: SyncTuneStrings.of(context).text(
            'Enter the complete HTTPS URL, including the remote music directory.',
          ),
        ),
        onChanged: (_) => _credentialFieldsChanged(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _username,
        enabled:
            !_busy &&
            !widget.controller.isRunning &&
            !widget.controller.configurationWriteInProgress,
        decoration: InputDecoration(
          labelText: SyncTuneStrings.of(context).text('Username'),
        ),
        onChanged: (_) => _credentialFieldsChanged(),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        enabled:
            !_busy &&
            !widget.controller.isRunning &&
            !widget.controller.configurationWriteInProgress,
        obscureText: !_passwordVisible,
        onChanged: (_) {
          if (_revealedSavedPassword) _editedRevealedPassword = true;
          setState(() {});
        },
        decoration: InputDecoration(
          labelText: SyncTuneStrings.of(context).text('Password'),
          helperText: SyncTuneStrings.of(context).text(
            _password.text.isNotEmpty
                ? 'This password will be saved in the system credential store.'
                : _savedCredentialUsable
                ? 'A password is saved for this account. Leave blank to keep it.'
                : 'Enter the WebDAV password.',
          ),
          suffixIcon: IconButton(
            tooltip: SyncTuneStrings.of(
              context,
            ).text(_passwordVisible ? 'Hide password' : 'Show saved password'),
            onPressed: _busy ? null : _togglePassword,
            icon: Icon(
              _passwordVisible ? Icons.visibility_off : Icons.visibility,
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _testCancellation != null
            ? () => _testCancellation?.cancel()
            : _busy ||
                  widget.controller.isRunning ||
                  widget.controller.configurationWriteInProgress
            ? null
            : _testConnection,
        icon: Icon(
          _testCancellation == null
              ? Icons.wifi_tethering
              : Icons.cancel_outlined,
        ),
        label: LocalizedText(
          _testCancellation == null
              ? 'Test connection'
              : 'Cancel connection test',
        ),
      ),
      if (_message != null) ...<Widget>[
        const SizedBox(height: 12),
        SelectableText(_message!),
      ],
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

String _remoteLabel(SyncSettings settings) => _effectiveRemoteUrl(settings);

String _effectiveRemoteUrl(SyncSettings settings) =>
    settings.effectiveRemoteUrl;

String? _canonicalUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
  final defaultPort = uri.scheme == 'https' ? 443 : 80;
  return uri
      .replace(
        port: uri.hasPort && uri.port != defaultPort ? uri.port : null,
        pathSegments: uri.pathSegments
            .where((part) => part.isNotEmpty)
            .toList(),
        query: null,
        fragment: null,
      )
      .toString();
}

String? _origin(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:$port';
}

String _accountKey(SyncSettings settings) =>
    '${_origin(_effectiveRemoteUrl(settings)) ?? ''}\n${settings.username.trim()}';

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
