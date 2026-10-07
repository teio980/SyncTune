import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synctune/app/shell/sync_tune_shell.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';

void main() {
  const grant = RootGrant(
    path: 'authorized',
    token: 'token',
    generation: 'generation',
  );

  testWidgets('failed root revoke keeps the authorization visible', (
    tester,
  ) async {
    var success = false;
    await tester.pumpWidget(
      ProviderScope(
        child: SyncTuneShell(
          onPickRoot: () async => grant,
          onRevokeRoot: (_) async => success,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.tap(find.text('Choose music root folder'));
    await tester.pump();

    await tester.tap(find.text('Revoke folder access'));
    await tester.pump();
    expect(
      find.text('Could not revoke access. Authorization remains active.'),
      findsOneWidget,
    );
    expect(find.text('Music root folder authorized'), findsOneWidget);

    success = true;
    await tester.tap(find.text('Revoke folder access'));
    await tester.pump();
    expect(find.text('Music root folder unavailable'), findsOneWidget);
  });

  testWidgets('revoke stays disabled when the platform has no revoker', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(child: SyncTuneShell(onPickRoot: () async => grant)),
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.tap(find.text('Choose music root folder'));
    await tester.pump();

    expect(
      find.text('Revocation unavailable on this platform.'),
      findsOneWidget,
    );
    final revoke = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Revoke folder access'),
    );
    expect(revoke.onPressed, isNull);
  });
}
