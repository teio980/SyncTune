import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/localization/strings.dart';
import 'package:synctune/app/sync_tune_app.dart';
import 'package:synctune/sync/sync_model.dart';

void main() {
  Widget app(SyncProgress progress) => MaterialApp(
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      SyncTuneStrings.delegate,
    ],
    supportedLocales: SyncTuneStrings.supportedLocales,
    home: Scaffold(body: SyncProgressSummary(progress: progress)),
  );

  testWidgets('unknown scan totals are shown without a fake denominator', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const SyncProgress(
          phase: SyncPhase.scanning,
          filesDone: 1,
          bytesDone: 3670016,
        ),
      ),
    );

    expect(find.text('Files scanned: 1'), findsOneWidget);
    expect(find.text('Data read: 3.5 MB'), findsOneWidget);
    expect(find.textContaining('/ 0'), findsNothing);
    expect(
      const SyncProgress(
        phase: SyncPhase.scanning,
        filesDone: 1,
        bytesDone: 3670016,
      ).fraction,
      isNull,
    );
  });

  testWidgets('known transfer totals use matching file and byte ranges', (
    tester,
  ) async {
    const progress = SyncProgress(
      phase: SyncPhase.transferring,
      filesDone: 1,
      fileCount: 2,
      bytesDone: 1048576,
      totalBytes: 2097152,
    );
    await tester.pumpWidget(app(progress));

    expect(find.text('Files processed: 1 / 2'), findsOneWidget);
    expect(find.text('Data transferred: 1.0 MB / 2.0 MB'), findsOneWidget);
    expect(progress.fraction, 0.5);
  });
}
