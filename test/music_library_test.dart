import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/sync/local_store.dart';
import 'package:synctune/sync/sync_model.dart';

void main() {
  late Directory root;
  late FileLocalStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synctune-music-library-');
    store = FileLocalStore(root.path);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('lists music metadata without including internal recovery content', () async {
    final album = Directory('${root.path}${Platform.pathSeparator}Album');
    await album.create();
    final song = File('${album.path}${Platform.pathSeparator}Song.MP3');
    await song.writeAsBytes(<int>[1, 2, 3]);
    final internal = Directory(
      '${root.path}${Platform.pathSeparator}.synctune-local-v2${Platform.pathSeparator}sync',
    );
    await internal.create(recursive: true);
    await File('${internal.path}${Platform.pathSeparator}kept.mp3')
        .writeAsString('x');
    await File('${root.path}${Platform.pathSeparator}notes.txt')
        .writeAsString('x');

    final tracks = await store.listMusic();

    expect(tracks.map((track) => track.path.value), <String>['Album/Song.MP3']);
    expect(tracks.single.size, 3);
    expect(tracks.single.modifiedMs, greaterThan(0));
  });

  test('deletes only the selected music file under the chosen root', () async {
    final song = File('${root.path}${Platform.pathSeparator}song.flac');
    await song.writeAsBytes(<int>[1, 2, 3]);
    final track = (await store.listMusic()).single;

    await store.deleteMusic(track);

    expect(await song.exists(), isFalse);
  });

  test(
    'legacy split WebDAV settings expose their existing complete target URL',
    () {
      const settings = SyncSettings(
        localRoot: 'music',
        localRootId: 'music-id',
        localGeneration: 'generation',
        serverUrl: 'https://example.test/dav',
        remoteRoot: 'Music/synctune',
        username: 'listener',
        language: 'en',
      );

      expect(
        settings.effectiveRemoteUrl,
        'https://example.test/dav/Music/synctune',
      );
      expect(settings.remoteRoot, 'Music/synctune');
    },
  );

  test('refuses non-music paths and stale selection metadata', () async {
    final file = File('${root.path}${Platform.pathSeparator}song.mp3');
    await file.writeAsBytes(<int>[1, 2, 3]);
    final track = (await store.listMusic()).single;
    await file.writeAsBytes(<int>[4, 5]);

    await expectLater(store.deleteMusic(track), throwsA(isA<SyncFailure>()));
    await expectLater(
      store.deleteMusic(
        SyncMusicTrack(
          path: SyncPath.parse('notes.txt'),
          size: 0,
          modifiedMs: 0,
        ),
      ),
      throwsA(isA<SyncFailure>()),
    );
    expect(await file.exists(), isTrue);
  });
}
