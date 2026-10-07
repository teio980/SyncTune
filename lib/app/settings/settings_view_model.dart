import 'package:flutter_riverpod/flutter_riverpod.dart';

final class WebDavSettings {
  const WebDavSettings({
    this.endpoint = '',
    this.username = '',
    this.password = '',
    this.clearPassword = false,
    this.credentialEpoch = '',
    this.credentialAccount = '',
    this.credentialAccountPresent = false,
  });

  final String endpoint;
  final String username;
  final String password;

  /// Empty password normally preserves the protected value. This flag is set
  /// only after the user explicitly clears the password field.
  final bool clearPassword;
  final String credentialEpoch;

  /// Opaque broker pointer restored by the composition port. It is never
  /// shown in the form and is versioned when a new password is committed.
  final String credentialAccount;

  /// Distinguishes a legacy record with no pointer from a new record whose
  /// pointer is intentionally empty after an explicit password clear.
  final bool credentialAccountPresent;

  bool get isValid {
    return canonicalWebDavEndpoint(endpoint) != null;
  }
}

/// Matches the endpoint rules used by the WebDAV repository. A trailing slash
/// is structural for URI resolution, so it is included exactly once in the
/// persisted identity.
String? canonicalWebDavEndpoint(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final segments = uri.pathSegments.toList();
  if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.' || segment == '..') return null;
    try {
      final decoded = Uri.decodeComponent(segment);
      if (decoded == '.' || decoded == '..') return null;
    } on FormatException {
      return null;
    }
  }
  final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
  return uri.replace(path: path).toString();
}

enum WebDavSaveStatus { idle, saving, saved, unavailable, failed }

final class WebDavSettingsState {
  const WebDavSettingsState({
    this.settings = const WebDavSettings(),
    this.status = WebDavSaveStatus.idle,
    this.message,
  });

  final WebDavSettings settings;
  final WebDavSaveStatus status;
  final String? message;
}

abstract interface class WebDavSettingsPort {
  Future<void> save(WebDavSettings settings);
}

/// Optional companion port used by a composition root that can restore the
/// last saved endpoint and username. Keeping loading separate preserves the
/// small save-only test seam used by settings screens and fakes.
abstract interface class WebDavSettingsLoader {
  Future<WebDavSettings> load();
}

/// Optional warning channel for a successful save that needed best-effort
/// cleanup (for example, an old vault entry could not be retired). The active
/// DB pointer is still valid, but the UI must make the cleanup failure visible.
abstract interface class WebDavSettingsWarningPort {
  String? takeWarning();
}

final webDavSettingsPortProvider = Provider<WebDavSettingsPort?>((ref) => null);

final class WebDavSettingsViewModel extends Notifier<WebDavSettingsState> {
  int _request = 0;
  bool _disposed = false;

  @override
  WebDavSettingsState build() {
    ref.onDispose(() => _disposed = true);
    final port = ref.read(webDavSettingsPortProvider);
    if (port case final WebDavSettingsLoader loader) {
      _load(loader);
    }
    return const WebDavSettingsState();
  }

  Future<void> _load(WebDavSettingsLoader loader) async {
    final request = ++_request;
    try {
      final settings = await loader.load();
      if (_disposed || request != _request) return;
      state = WebDavSettingsState(settings: settings);
    } catch (_) {
      // The empty form remains usable when a platform credential read or
      // database restore is unavailable. Save errors remain user-visible.
    }
  }

  void setEndpoint(String value) => _update(endpoint: value);

  void setUsername(String value) => _update(username: value);

  void setPassword(String value) =>
      _update(password: value, clearPassword: value.isEmpty);

  void _update({
    String? endpoint,
    String? username,
    String? password,
    bool? clearPassword,
  }) {
    _request++;
    final current = state.settings;
    state = WebDavSettingsState(
      settings: WebDavSettings(
        endpoint: endpoint ?? current.endpoint,
        username: username ?? current.username,
        password: password ?? current.password,
        clearPassword: clearPassword ?? current.clearPassword,
        credentialEpoch: current.credentialEpoch,
        credentialAccount: current.credentialAccount,
        credentialAccountPresent: current.credentialAccountPresent,
      ),
    );
  }

  Future<void> save(WebDavSettingsPort? port) async {
    final request = ++_request;
    if (port == null) {
      if (_disposed || request != _request) return;
      state = WebDavSettingsState(
        settings: state.settings,
        status: WebDavSaveStatus.unavailable,
        message: '远端服务尚未连接',
      );
      return;
    }
    if (!state.settings.isValid) {
      if (_disposed || request != _request) return;
      state = WebDavSettingsState(
        settings: state.settings,
        status: WebDavSaveStatus.failed,
        message: '请输入有效的 HTTPS WebDAV 地址',
      );
      return;
    }
    final settings = state.settings;
    if (_disposed || request != _request) return;
    state = WebDavSettingsState(
      settings: settings,
      status: WebDavSaveStatus.saving,
    );
    try {
      await port.save(settings);
      final warning = port is WebDavSettingsWarningPort
          ? (port as WebDavSettingsWarningPort).takeWarning()
          : null;
      if (_disposed || request != _request) return;
      state = WebDavSettingsState(
        settings: settings,
        status: WebDavSaveStatus.saved,
        message: warning ?? '设置已保存',
      );
    } catch (_) {
      if (_disposed || request != _request) return;
      state = WebDavSettingsState(
        settings: settings,
        status: WebDavSaveStatus.failed,
        message: '设置保存失败，请稍后重试',
      );
    }
  }
}

final webDavSettingsProvider =
    NotifierProvider<WebDavSettingsViewModel, WebDavSettingsState>(
      WebDavSettingsViewModel.new,
    );
