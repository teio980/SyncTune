import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef RootGrantLoader = Future<RootGrant?> Function();

final class RootGrant {
  const RootGrant({
    required this.path,
    required this.token,
    required this.generation,
  });
  final String path;
  final String token;
  final String generation;
}

final class RootGrantViewModel extends Notifier<RootGrant?> {
  int _request = 0;
  bool _disposed = false;

  @override
  RootGrant? build() {
    ref.onDispose(() => _disposed = true);
    return null;
  }

  bool _current(int request) => !_disposed && request == _request;

  void setGrant(RootGrant grant) {
    ++_request;
    state = grant;
    ref.read(rootAccessStatusProvider.notifier).setStatus('ready');
  }

  Future<void> restore(RootGrantLoader restorer) async {
    final request = ++_request;
    ref.read(rootAccessStatusProvider.notifier).setStatus('loading');
    try {
      final grant = await restorer();
      if (!_current(request)) return;
      if (grant == null) {
        state = null;
        ref.read(rootAccessStatusProvider.notifier).setStatus('none');
      } else {
        state = grant;
        ref.read(rootAccessStatusProvider.notifier).setStatus('ready');
      }
    } catch (_) {
      if (_current(request)) {
        state = null;
        ref.read(rootAccessStatusProvider.notifier).setStatus('error');
      }
    }
  }

  Future<void> pick(RootGrantLoader picker) async {
    final request = ++_request;
    ref.read(rootAccessStatusProvider.notifier).setStatus('loading');
    try {
      final grant = await picker();
      if (!_current(request)) return;
      if (grant == null) {
        ref
            .read(rootAccessStatusProvider.notifier)
            .setStatus(state == null ? 'none' : 'ready');
      } else {
        state = grant;
        ref.read(rootAccessStatusProvider.notifier).setStatus('ready');
      }
    } catch (_) {
      if (_current(request)) {
        state = null;
        ref.read(rootAccessStatusProvider.notifier).setStatus('error');
      }
    }
  }

  void clear() {
    ++_request;
    state = null;
    ref.read(rootAccessStatusProvider.notifier).setStatus('revoked');
  }
}

final rootGrantProvider = NotifierProvider<RootGrantViewModel, RootGrant?>(
  RootGrantViewModel.new,
);

final class RootAccessStatusViewModel extends Notifier<String> {
  @override
  String build() => 'none';

  void setStatus(String value) => state = value;
}

final rootAccessStatusProvider =
    NotifierProvider<RootAccessStatusViewModel, String>(
      RootAccessStatusViewModel.new,
    );

final class SyncStatusViewModel extends Notifier<String> {
  @override
  String build() => 'idle';

  void setStatus(String value) => state = value;
}

final syncStatusProvider = NotifierProvider<SyncStatusViewModel, String>(
  SyncStatusViewModel.new,
);
