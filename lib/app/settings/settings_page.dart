import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/sync_components.dart';
import '../design/sync_theme.dart';
import '../design/theme_mode.dart';
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
        setState(() => _revokeError = '目录撤销失败，当前授权仍保持。');
      } else if (sameGrant) {
        ref.read(rootGrantProvider.notifier).clear();
      }
    } catch (_) {
      if (mounted) setState(() => _revokeError = '目录撤销失败，当前授权仍保持。');
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
    final webDavBusy = webDav.status == WebDavSaveStatus.saving;
    final themeMode = ref.watch(themeModeProvider);
    final themePort = ref.watch(themePreferencePortProvider);

    return SyncTunePageScaffold(
      title: '设置',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SyncTuneSection(
            title: '授权与连接',
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
                      label: Text(_pickBusy ? '正在打开系统选择器…' : '选择音乐根目录'),
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
                      label: Text(_revokeBusy ? '正在撤销授权…' : '撤销目录授权'),
                    ),
                  ],
                ),
                if (grant != null && widget.onRevokeRoot == null) ...[
                  const SizedBox(height: SyncTuneTokens.space8),
                  const Text('当前平台未提供撤销服务。'),
                ],
                if (_revokeError != null) ...[
                  const SizedBox(height: SyncTuneTokens.space8),
                  Text(
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
                    label: const Text('打开平台诊断'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: SyncTuneTokens.space32),
          SyncTuneSection(
            title: '外观',
            description: '默认跟随系统，也可以为本设备选择浅色或深色。',
            child: DropdownButtonFormField<ThemeMode>(
              initialValue: themeMode,
              decoration: const InputDecoration(
                labelText: '主题模式',
                prefixIcon: Icon(Icons.brightness_6_outlined),
              ),
              items: const [
                DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
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
            const Text('主题选择将在本次运行中生效；偏好存储服务尚未连接。'),
          ],
          const SizedBox(height: SyncTuneTokens.space32),
          SyncTuneSection(
            title: '凭据与 WebDAV',
            description: '保存连接信息后，完成底层兼容性检查才能启用同步。',
            child: _WebDavForm(
              endpointController: _endpointController,
              usernameController: _usernameController,
              passwordController: _passwordController,
              state: webDav,
              portAvailable: webDavPort != null,
              busy: webDavBusy,
              onEndpointChanged: _onEndpointChanged,
              onUsernameChanged: _onUsernameChanged,
              onPasswordChanged: _onPasswordChanged,
              onSave: webDavPort == null || webDavBusy
                  ? null
                  : () => ref
                        .read(webDavSettingsProvider.notifier)
                        .save(webDavPort),
            ),
          ),
          const SizedBox(height: SyncTuneTokens.space32),
          const SyncTuneStatusCard(
            title: '权限状态',
            message: '平台权限验证完成后，同步功能才会开放。目录授权、完整扫描、远端兼容性和平台安全闸门也必须通过。',
            icon: Icons.security_outlined,
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
        title: '正在确认目录授权',
        message: '请稍候。',
        icon: Icons.hourglass_top_outlined,
      ),
      'error' || 'revoked' => const SyncTuneStatusCard(
        title: '音乐根目录不可用',
        message: '授权已失效，请重新选择音乐根目录。',
        icon: Icons.folder_off_outlined,
        tone: SyncTuneStatusTone.error,
      ),
      _ when grant != null => SyncTuneStatusCard(
        title: '音乐根目录已授权',
        message: '仅访问你选择的目录。',
        icon: Icons.folder_shared_outlined,
        tone: SyncTuneStatusTone.positive,
        action: SyncTuneKeyValue(label: '目录', value: grant.path),
      ),
      _ => const SyncTuneStatusCard(
        title: '未选择音乐根目录',
        message: '请选择一个音乐目录开始使用 SyncTune。',
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
    required this.busy,
    required this.onEndpointChanged,
    required this.onUsernameChanged,
    required this.onPasswordChanged,
    required this.onSave,
  });

  final TextEditingController endpointController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final WebDavSettingsState state;
  final bool portAvailable;
  final bool busy;
  final ValueChanged<String> onEndpointChanged;
  final ValueChanged<String> onUsernameChanged;
  final ValueChanged<String> onPasswordChanged;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final message = state.message;
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
          decoration: const InputDecoration(
            labelText: 'WebDAV 地址',
            hintText: 'https://example.com/music',
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: SyncTuneTokens.space12),
        TextField(
          controller: usernameController,
          onChanged: onUsernameChanged,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '用户名',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: SyncTuneTokens.space12),
        TextField(
          controller: passwordController,
          onChanged: onPasswordChanged,
          obscureText: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: '密码',
            prefixIcon: Icon(Icons.password_outlined),
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
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(busy ? '保存中…' : '保存 WebDAV 设置'),
            ),
            if (!portAvailable) const Text('远端服务尚未连接，保存功能暂不可用。'),
          ],
        ),
        if (message != null) ...[
          const SizedBox(height: SyncTuneTokens.space12),
          SyncTuneStatusCard(
            title: state.status == WebDavSaveStatus.saved ? '已保存' : '设置状态',
            message: message,
            icon: state.status == WebDavSaveStatus.failed
                ? Icons.error_outline
                : Icons.info_outline,
            tone: statusTone,
          ),
        ],
      ],
    );
  }
}
