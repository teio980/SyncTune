import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/localization/strings.dart';
import 'package:synctune/app/music/music_deletion.dart';
import 'package:synctune/app/music/music_page.dart';
import 'package:synctune/app/music/music_scan.dart';
import 'package:synctune/app/music/music_scan_port.dart';
import 'package:synctune/app/sync/sync_gate.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';
import 'package:synctune/data/sync_tune_database.dart';

final class _FakeScanner implements MusicScannerPort {
  _FakeScanner(this.items);
  final List<Map<Object?, Object?>> items;

  @override
  Future<Map<Object?, Object?>> scan(RootGrant grant) async => {
    'status': 'ok',
    'generation': grant.generation,
    'complete': true,
    'items': items,
  };
}

final class _FakeDeletionPort implements MusicDeletionPort {
  final List<String> deletedPaths = [];
  final List<DeletionTaskRecord> tasks = [];

  @override
  Future<void> deleteSong({
    required String relativePath,
    required String expectedSha256,
    String? entryId,
  }) async {
    deletedPaths.add(relativePath);
  }

  @override
  Future<List<DeletionTaskRecord>> pendingTasks() async => tasks;

  @override
  Future<void> recoverTasks() async {}
}

void main() {
  const grant = RootGrant(
    path: 'authorized',
    token: 'token',
    generation: 'generation',
  );

  final sampleItems = [
    <Object?, Object?>{
      'id': 'entry-1',
      'relativePath': 'artist/song.mp3',
      'size': 1024,
      'extension': 'mp3',
      'sha256': 'a' * 64,
    },
  ];

  Widget buildSubject({
    required ProviderContainer container,
    Locale locale = const Locale('zh'),
    bool expanded = false,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        supportedLocales: SyncTuneStrings.supportedLocales,
        localizationsDelegates: const [
          SyncTuneStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: MusicPage(expandedLayout: expanded),
        ),
      ),
    );
  }

  testWidgets('delete confirmation dialog displays filename and exact Chinese prompt', (
    WidgetTester tester,
  ) async {
    final fakePort = _FakeDeletionPort();
    final container = ProviderContainer(
      overrides: [
        musicScannerPortProvider.overrideWithValue(_FakeScanner(sampleItems)),
        musicDeletionPortProvider.overrideWithValue(fakePort),
      ],
    );
    addTearDown(container.dispose);

    container.read(rootGrantProvider.notifier).setGrant(grant);
    await container.read(musicScanProvider.notifier).scan(grant);

    await tester.pumpWidget(buildSubject(container: container, locale: const Locale('zh')));
    await tester.pumpAndSettle();

    expect(find.text('artist/song.mp3'), findsOneWidget);
    final deleteButton = find.byIcon(Icons.delete_outline);
    expect(deleteButton, findsOneWidget);

    // Tap delete button to open confirmation dialog
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    // Verify dialog title and contents
    expect(find.text('删除歌曲'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('song.mp3'),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('删除本机歌曲及 WebDAV 副本，其他设备将在下次同步时删除。'),
      findsOneWidget,
    );

    // Tap Cancel
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(fakePort.deletedPaths, isEmpty);
    // Song should still be in the list
    expect(find.text('artist/song.mp3'), findsOneWidget);
  });

  testWidgets('confirming delete removes song and calls deletion port', (
    WidgetTester tester,
  ) async {
    final fakePort = _FakeDeletionPort();
    final container = ProviderContainer(
      overrides: [
        musicScannerPortProvider.overrideWithValue(_FakeScanner(sampleItems)),
        musicDeletionPortProvider.overrideWithValue(fakePort),
      ],
    );
    addTearDown(container.dispose);

    container.read(rootGrantProvider.notifier).setGrant(grant);
    await container.read(musicScanProvider.notifier).scan(grant);

    await tester.pumpWidget(buildSubject(container: container, locale: const Locale('zh')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    // Tap Confirm delete
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(fakePort.deletedPaths, contains('artist/song.mp3'));
    // Song removed from list immediately
    expect(find.text('artist/song.mp3'), findsNothing);
  });

  testWidgets('English locale displays exact English prompt in dialog', (
    WidgetTester tester,
  ) async {
    final fakePort = _FakeDeletionPort();
    final container = ProviderContainer(
      overrides: [
        musicScannerPortProvider.overrideWithValue(_FakeScanner(sampleItems)),
        musicDeletionPortProvider.overrideWithValue(fakePort),
      ],
    );
    addTearDown(container.dispose);

    container.read(rootGrantProvider.notifier).setGrant(grant);
    await container.read(musicScanProvider.notifier).scan(grant);

    await tester.pumpWidget(buildSubject(container: container, locale: const Locale('en')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('Delete song'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('song.mp3'),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Delete local song and WebDAV copy. Other devices will delete it on their next sync.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('delete button is disabled while sync is running', (
    WidgetTester tester,
  ) async {
    final fakePort = _FakeDeletionPort();
    final container = ProviderContainer(
      overrides: [
        musicScannerPortProvider.overrideWithValue(_FakeScanner(sampleItems)),
        musicDeletionPortProvider.overrideWithValue(fakePort),
        syncRuntimeSnapshotProvider.overrideWith(
          (ref) => Stream.value(
            const ForegroundRuntimeSnapshot(
              phase: ForegroundRunPhase.running,
              message: 'Syncing',
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(rootGrantProvider.notifier).setGrant(grant);
    await container.read(musicScanProvider.notifier).scan(grant);

    await tester.pumpWidget(buildSubject(container: container));
    await tester.pumpAndSettle();

    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_outline),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('displays 本机已删除，等待同步 status card when tasks are pending', (
    WidgetTester tester,
  ) async {
    final fakePort = _FakeDeletionPort();
    fakePort.tasks.add(DeletionTaskRecord(
      operationId: 'op-1',
      rootId: 'token|generation',
      generation: 'generation',
      remoteNamespace: 'default',
      entryId: 'entry-1',
      relativePath: 'artist/song.mp3',
      expectedSha256: 'a' * 64,
      stage: 'local_deleted',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    final container = ProviderContainer(
      overrides: [
        musicScannerPortProvider.overrideWithValue(_FakeScanner(sampleItems)),
        musicDeletionPortProvider.overrideWithValue(fakePort),
      ],
    );
    addTearDown(container.dispose);

    container.read(rootGrantProvider.notifier).setGrant(grant);
    await container.read(musicScanProvider.notifier).scan(grant);

    await tester.pumpWidget(buildSubject(container: container, locale: const Locale('zh')));
    await tester.pumpAndSettle();

    // Check pending tasks
    await container.read(musicDeletionProvider.notifier).checkPendingTasks();
    await tester.pumpAndSettle();

    expect(find.text('本机已删除，等待同步'), findsOneWidget);
  });
}
