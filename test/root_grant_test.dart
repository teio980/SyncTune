import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';

void main() {
  const oldGrant = RootGrant(
    path: 'old',
    token: 'old-token',
    generation: 'old-generation',
  );
  const newGrant = RootGrant(
    path: 'new',
    token: 'new-token',
    generation: 'new-generation',
  );

  test('a late restore cannot overwrite a newer root selection', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final restoreCompleter = Completer<RootGrant?>();
    final pickCompleter = Completer<RootGrant?>();
    final viewModel = container.read(rootGrantProvider.notifier);

    final restore = viewModel.restore(() => restoreCompleter.future);
    final pick = viewModel.pick(() => pickCompleter.future);
    pickCompleter.complete(newGrant);
    await pick;
    restoreCompleter.complete(oldGrant);
    await restore;

    expect(container.read(rootGrantProvider), newGrant);
    expect(container.read(rootAccessStatusProvider), 'ready');
  });

  test('a missing restore clears the existing root', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final viewModel = container.read(rootGrantProvider.notifier);
    viewModel.setGrant(oldGrant);

    await viewModel.restore(() async => null);

    expect(container.read(rootGrantProvider), isNull);
    expect(container.read(rootAccessStatusProvider), 'none');
  });

  test('a direct grant update invalidates a pending restore', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final completer = Completer<RootGrant?>();
    final viewModel = container.read(rootGrantProvider.notifier);
    final restore = viewModel.restore(() => completer.future);
    viewModel.setGrant(newGrant);
    completer.complete(oldGrant);
    await restore;

    expect(container.read(rootGrantProvider), newGrant);
    expect(container.read(rootAccessStatusProvider), 'ready');
  });

  test(
    'a failed selection clears the grant and exposes error status',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final viewModel = container.read(rootGrantProvider.notifier);
      viewModel.setGrant(oldGrant);

      await viewModel.pick(
        () async => throw StateError('provider unavailable'),
      );

      expect(container.read(rootGrantProvider), isNull);
      expect(container.read(rootAccessStatusProvider), 'error');
    },
  );

  test(
    'revocation clears the root and prevents a stale picker result',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final completer = Completer<RootGrant?>();
      final viewModel = container.read(rootGrantProvider.notifier);
      final pick = viewModel.pick(() => completer.future);
      viewModel.clear();
      completer.complete(newGrant);
      await pick;

      expect(container.read(rootGrantProvider), isNull);
      expect(container.read(rootAccessStatusProvider), 'revoked');
    },
  );

  test('a disposed provider ignores a late picker result', () async {
    final container = ProviderContainer();
    final completer = Completer<RootGrant?>();
    final pick = container
        .read(rootGrantProvider.notifier)
        .pick(() => completer.future);
    container.dispose();
    completer.complete(newGrant);
    await expectLater(pick, completes);
  });
}
