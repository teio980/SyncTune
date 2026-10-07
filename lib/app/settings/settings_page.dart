import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/sync_components.dart';
import '../design/sync_theme.dart';
import '../design/theme_mode.dart';
import '../localization/language.dart';
import '../localization/strings.dart';
import '../sync/sync_status_view_model.dart';
import 'settings_view_model.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({
    required this.onPickRoot,
    required this.diagnosticsBuilder,
    super.key,
    this.onRevokeRoot,
  });

  final Future<RootGrant?> Function()? onPickRoot;
  final Future<bool> Function(RootGrant grant)? onRevokeRoot;
  final WidgetBuilder? diagnosticsBuilder;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _endpointController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _pickBusy = false;
  bool _revokeBusy = false;
  bool _webDavEdited = false;
  String? _revokeError;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(webDavSettingsProvider).settings;
    _endpointController = TextEditingController(text: settings.endpoint);
    _usernameController = TextEditingController(text: settings.username);
    _passwordController = TextEditingController(text: settings.password);
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _chooseRoot() async {
    final picker = widget.onPickRoot;
    if (picker == null || _pickBusy) return;
    setState(() => _pickBusy = true);
    try {
      await ref.read(rootGrantProvider.notifier).pick(picker);
    } finally {
      if (mounted) setState(() => _pickBusy = false);
    }
  }

  Future<void> _revokeRoot(RootGrant grant) async {
    final revoker = widget.onRevokeRoot;
    if (revoker == null || _revokeBusy) return;
    setState(() {
      _revokeBusy = true;
      _revokeError = null;
    });
    try {
      final success = await revoker(grant);
      if (!mounted) return;
      final current = ref.read(rootGrantProvider);
      final sameGrant =
          current?.token == grant.token &&
          current?.generation == grant.generation;
      if (!success) {
        setState(
          () => _revokeError = 'Could not revoke access. Authorization remains active.',
        );
      } else if (sameGrant) {
        ref.read(rootGrantProvider.notifier).clear();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _revokeError = 'Could not revoke access. Authorization remains active.',
        );
      }
    } finally {
      if (mounted) setState(() => _revokeBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grant = ref.watch(rootGrantProvider);
    final rootStatus = ref.watch(rootAccessStatusProvider);
    final webDav = ref.watch(webDavSettingsProvider);
    _syncWebDavControllers(webDav.settings);
    final webDavPort = ref.watch(webDavSettingsPortProvider);
    final connectionPort = ref.watch(webDavConnectionCheckPortProvider);
    final webDavBusy =
        webDav.status == WebDavSaveStatus.saving ||
        webDav.connectionStatus == WebDavConnectionStatus.checking;
    final themeMode = ref.watch(themeModeProvider);
    final themePort = ref.watch(themePreferencePortProvider);
    final languageState = ref.watch(languageProvider);
    final languagePort = ref.watch(languagePreferencePortProvider);

    return SyncTunePageScaffold(
      title: 'Settings',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SyncTuneSection(
            title: 'Language',
            child: DropdownButtonFormField<AppLanguage>(
              key: ValueKey(languageState.language),
              initialValue: languageState.language,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: SyncTuneStrings.of(context).text('App language'),
                prefixIcon: const Icon(Icons.language),
              ),
              items: const [
                DropdownMenuItem(
                  value: AppLanguage.english,
                  child: LocalizedText('English'),
                ),
                DropdownMenuItem(
                  value: AppLanguage.chinese,
                  child: LocalizedText('Chinese'),
                ),
              ],
              onChanged: (language) {
                if (language != null) {
                  ref.read(languageProvider.notifier).select(language);
                }
              },
            ),
          ),
          if (languagePort == null) ...[
            const SizedBox(height: SyncTuneTokens.space8),
            const LocalizedText('Session only'),
          ],
          if (languageState.saveFailed) ...[
            const SizedBox(height: SyncTuneTokens.space8),
            const LocalizedText('Could not save preference.'),
          ],
          const SizedBox(height: SyncTuneTokens.space32),
          SyncTuneSection(
            title: 'Access and connection',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _rootCard(grant: grant, status: rootStatus),
                const SizedBox(height: SyncTuneTokens.space12),
                Wrap(
                  spacing: SyncTuneTokens.space12,
                  runSpacing: SyncTuneTokens.space8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: widget.onPickRoot == null || _pickBusy
                          ? null
                          : _chooseRoot,
                      icon: _pickBusy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.folder_open),
                      label: LocalizedText(
                        _pickBusy
                            ? 'Opening folder picker…'
                            : 'Choose music root folder',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          grant == null ||
                              widget.onRevokeRoot == null ||
                              _revokeBusy
                          ? null
                          : () => _revokeRoot(grant),
                      icon: _revokeBusy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.folder_off_outlined),
                      label: LocalizedText(
                        _revokeBusy
                            ? 'Revoking access…'
                            : 'Revoke folder access',
                      ),
                    ),
                  ],
                ),
                if (grant != null && widget.onRevokeRoot == null) ...[
                  const SizedBox(height: SyncTuneTokens.space8),
                  const LocalizedText(
                    'Revocation unavailable on this platform.',
                  ),
                ],
                if (_revokeError != null) ...[
                  const SizedBox(height: SyncTuneTokens.space8),
                  LocalizedText(
                    _revokeError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (widget.diagnosticsBuilder != null) ...[
                  const SizedBox(height: SyncTuneTokens.space12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: widget.diagnosticsBuilder!),
                    ),
                    icon: const Icon(Icons.science_outlined),
                    label: const LocalizedText('Open platform diagnostics'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: SyncTuneTokens.space32),
          SyncTuneSection(
            title: 'Appearance',
            child: DropdownButtonFormField<ThemeMode>(
              isExpanded: true,
              initialValue: themeMode,
              decoration: InputDecoration(
                labelText: SyncTuneStrings.of(context).text('Theme mode'),
                prefixIcon: const Icon(Icons.brightness_6_outlined),
              ),
              items: const [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: LocalizedText('System'),
                ),
                DropdownMenuItem(
                  value: ThemeMode.light,
                  child: LocalizedText('Light'),
                ),
                DropdownMenuItem(
                  value: ThemeMode.dark,
                  child: LocalizedText('Dark'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  ref.read(themeModeProvider.notifier).select(value);
                }
              },
            ),
          ),
          if (themePort == null) ...[
            const SizedBox(height: SyncTuneTokens.space8),
            const LocalizedText('Session only'),
          ],
          const SizedBox(height: SyncTuneTokens.space32),
          SyncTuneSection(
            title: 'Credentials and WebDAV',
            child: _WebDavForm(
              endpointController: _endpointController,
              usernameController: _usernameController,
              passwordController: _passwordController,
              state: webDav,
              portAvailable: webDavPort != null,
              onEndpointChanged: _onEndpointChanged,
              onUsernameChanged: _onUsernameChanged,
              onPasswordChanged: _onPasswordChanged,
              onSave: webDavPort == null || webDavBusy
                  ? null
                  : () => ref
                        .read(webDavSettingsProvider.notifier)
                        .save(webDavPort),
              onCheckConnection: connectionPort == null || webDavBusy
                  ? null
                  : () => ref
                        .read(webDavSettingsProvider.notifier)
                        .checkConnection(connectionPort),
            ),
          ),
        ],
      ),
    );
  }

  void _syncWebDavControllers(WebDavSettings settings) {
    if (_webDavEdited) return;
    if (_endpointController.text != settings.endpoint) {
      _endpointController.text = settings.endpoint;
    }
    if (_usernameController.text != settings.username) {
      _usernameController.text = settings.username;
    }
    if (_passwordController.text != settings.password) {
      _passwordController.text = settings.password;
    }
  }

  void _onEndpointChanged(String value) {
    _webDavEdited = true;
    ref.read(webDavSettingsProvider.notifier).setEndpoint(value);
  }

  void _onUsernameChanged(String value) {
    _webDavEdited = true;
    ref.read(webDavSettingsProvider.notifier).setUsername(value);
  }

  void _onPasswordChanged(String value) {
    _webDavEdited = true;
    ref.read(webDavSettingsProvider.notifier).setPassword(value);
  }

  Widget _rootCard({required RootGrant? grant, required String status}) {
    final card = switch (status) {
      'loading' => const SyncTuneStatusCard(
        title: 'Checking folder access',
        icon: Icons.hourglass_top_outlined,
      ),
      'error' || 'revoked' => const SyncTuneStatusCard(
        title: 'Music root folder unavailable',
        message: 'Choose the folder again.',
        icon: Icons.folder_off_outlined,
        tone: SyncTuneStatusTone.error,
      ),
      _ when grant != null => SyncTuneStatusCard(
        title: 'Music root folder authorized',
        icon: Icons.folder_shared_outlined,
        tone: SyncTuneStatusTone.positive,
        action: SyncTuneKeyValue(label: 'Folder', value: grant.path),
      ),
      _ => const SyncTuneStatusCard(
        title: 'No music root folder selected',
        icon: Icons.folder_outlined,
      ),
    };
    return card;
  }
}

class _WebDavForm extends StatelessWidget {
  const _WebDavForm({
    required this.endpointController,
    required this.usernameController,
    required this.passwordController,
    required this.state,
    required this.portAvailable,
    required this.onEndpointChanged,
    required this.onUsernameChanged,
    required this.onPasswordChanged,
    required this.onSave,
    required this.onCheckConnection,
  });

  final TextEditingController endpointController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final WebDavSettingsState state;
  final bool portAvailable;
  final ValueChanged<String> onEndpointChanged;
  final ValueChanged<String> onUsernameChanged;
  final ValueChanged<String> onPasswordChanged;
  final VoidCallback? onSave;
  final VoidCallback? onCheckConnection;

  @override
  Widget build(BuildContext context) {
    final message = state.message;
    final saving = state.status == WebDavSaveStatus.saving;
    final checking = state.connectionStatus == WebDavConnectionStatus.checking;
    final statusTone = state.status == WebDavSaveStatus.failed
        ? SyncTuneStatusTone.error
        : state.status == WebDavSaveStatus.saved
        ? SyncTuneStatusTone.positive
        : SyncTuneStatusTone.neutral;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: endpointController,
          onChanged: onEndpointChanged,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: SyncTuneStrings.of(context).text('WebDAV URL'),
            hintText: 'https://example.com/music',
            prefixIcon: const Icon(Icons.link),
          ),
        ),
        const SizedBox(height: SyncTuneTokens.space12),
        TextField(
          controller: usernameController,
          onChanged: onUsernameChanged,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: SyncTuneStrings.of(context).text('Username'),
            prefixIcon: const Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: SyncTuneTokens.space12),
        TextField(
          controller: passwordController,
          onChanged: onPasswordChanged,
          obscureText: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: SyncTuneStrings.of(context).text('Password'),
            prefixIcon: const Icon(Icons.password_outlined),
          ),
        ),
        const SizedBox(height: SyncTuneTokens.space12),
        Wrap(
          spacing: SyncTuneTokens.space12,
          runSpacing: SyncTuneTokens.space8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: onSave,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: LocalizedText(saving ? 'Saving…' : 'Save WebDAV settings'),
            ),
            OutlinedButton.icon(
              onPressed: onCheckConnection,
              icon: checking
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering_outlined),
              label: LocalizedText(
                checking ? 'Checking connection…' : 'Check connection status',
              ),
            ),
            if (!portAvailable)
              const LocalizedText(
                'WebDAV service unavailable.',
              ),
          ],
        ),
        if (message != null) ...[
          const SizedBox(height: SyncTuneTokens.space12),
          SyncTuneStatusCard(
            title: state.status == WebDavSaveStatus.saved
                ? 'Settings saved'
                : 'Settings status',
            message: state.status == WebDavSaveStatus.saved ? '' : message,
            icon: state.status == WebDavSaveStatus.failed
                ? Icons.error_outline
                : Icons.info_outline,
            tone: statusTone,
          ),
        ],
        if (state.connectionMessage != null) ...[
          const SizedBox(height: SyncTuneTokens.space12),
          Semantics(
            liveRegion: true,
            child: SyncTuneStatusCard(
              title: switch (state.connectionStatus) {
                WebDavConnectionStatus.connected => 'Connection successful',
                WebDavConnectionStatus.failed => 'Connection check failed',
                _ => 'Connection status',
              },
              message: state.connectionMessage!,
              icon: switch (state.connectionStatus) {
                WebDavConnectionStatus.connected => Icons.check_circle_outline,
                WebDavConnectionStatus.failed => Icons.error_outline,
                _ => Icons.info_outline,
              },
              tone: switch (state.connectionStatus) {
                WebDavConnectionStatus.connected => SyncTuneStatusTone.positive,
                WebDavConnectionStatus.failed => SyncTuneStatusTone.error,
                _ => SyncTuneStatusTone.neutral,
              },
            ),
          ),
        ],
      ],
    );
  }
}
