import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/settings/settings_view_model.dart';

final class _PendingSave implements WebDavSettingsPort {
  final complete = Completer<void>();

  @override
  Future<void> save(WebDavSettings settings) => complete.future;
}

void main() {
  test('a pending save cannot replace a newer endpoint edit', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final viewModel = container.read(webDavSettingsProvider.notifier);
    viewModel.setEndpoint('https://first.example/music');
    final pending = _PendingSave();
    final save = viewModel.save(pending);

    viewModel.setEndpoint('https://second.example/music');
    pending.complete.complete();
    await save;

    final state = container.read(webDavSettingsProvider);
    expect(state.settings.endpoint, 'https://second.example/music');
    expect(state.status, WebDavSaveStatus.idle);
  });

  test('a missing service never reports a false successful save', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final viewModel = container.read(webDavSettingsProvider.notifier);
    viewModel.setEndpoint('https://dav.example/music');

    await viewModel.save(null);

    expect(
      container.read(webDavSettingsProvider).status,
      WebDavSaveStatus.unavailable,
    );
  });

  test('a successful save surfaces credential cleanup warnings', () async {
    final container = ProviderContainer(
      overrides: [webDavSettingsPortProvider.overrideWithValue(_WarningSave())],
    );
    addTearDown(container.dispose);
    final viewModel = container.read(webDavSettingsProvider.notifier);
    viewModel.setEndpoint('https://dav.example/music');

    await viewModel.save(container.read(webDavSettingsPortProvider));

    final state = container.read(webDavSettingsProvider);
    expect(state.status, WebDavSaveStatus.saved);
    expect(state.message, contains('清理失败'));
  });
}

final class _WarningSave
    implements WebDavSettingsPort, WebDavSettingsWarningPort {
  @override
  Future<void> save(WebDavSettings settings) async {}

  @override
  String? takeWarning() => '旧 WebDAV 凭据清理失败，当前设置仍已生效。';
}
