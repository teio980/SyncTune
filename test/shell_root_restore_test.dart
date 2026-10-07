import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/shell/sync_tune_shell.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';

void main() {
  testWidgets('root grant is restored after returning from the system picker', (
    tester,
  ) async {
    var restores = 0;
    const grant = RootGrant(
      path: 'test-root',
      token: 'test-token',
      generation: 'test-generation',
    );

    await tester.pumpWidget(
      ProviderScope(
        child: SyncTuneShell(
          onRestoreRoot: () async {
            restores++;
            return grant;
          },
        ),
      ),
    );
    await tester.pump();
    expect(
      restores,
      1,
      reason: 'the shell restores the saved grant at startup',
    );

    restores = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 250));
    expect(restores, 1, reason: 'resume reloads the grant after picker return');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });
}
