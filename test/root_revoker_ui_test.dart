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
    await tester.tap(find.text('选择音乐根目录'));
    await tester.pump();

    await tester.tap(find.text('撤销目录授权'));
    await tester.pump();
    expect(find.text('授权撤销失败，当前授权仍有效。'), findsOneWidget);
    expect(find.text('音乐根目录已授权'), findsOneWidget);

    success = true;
    await tester.tap(find.text('撤销目录授权'));
    await tester.pump();
    expect(find.text('音乐根目录不可用'), findsOneWidget);
  });

  testWidgets('revoke stays disabled when the platform has no revoker', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(child: SyncTuneShell(onPickRoot: () async => grant)),
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.tap(find.text('选择音乐根目录'));
    await tester.pump();

    expect(find.text('当前平台不支持撤销授权。'), findsOneWidget);
    final revoke = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '撤销目录授权'),
    );
    expect(revoke.onPressed, isNull);
  });
}
