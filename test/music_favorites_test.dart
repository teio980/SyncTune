import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/music/music_scan.dart';
import 'package:synctune/app/sync/sync_status_view_model.dart';

final class _FavoritesPort implements MusicFavoritesPort {
  final values = <String>{};

  @override
  Future<Set<String>> loadFavorites(RootGrant grant) async =>
      Set<String>.of(values);

  @override
  Future<void> setFavorite({
    required RootGrant grant,
    required MusicTrack track,
    required bool value,
  }) async {
    final id = track.id ?? track.relativePath;
    if (value) {
      values.add(id);
    } else {
      values.remove(id);
    }
  }
}

void main() {
  test(
    'favorites use a stable entry id when the scanner provides one',
    () async {
      final port = _FavoritesPort();
      final container = ProviderContainer(
        overrides: [musicFavoritesPortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      final track = MusicTrack(
        id: 'entry-1',
        relativePath: 'album/song.mp3',
        size: 12,
        extension: 'mp3',
      );
      const grant = RootGrant(
        path: 'authorized',
        token: 'token',
        generation: 'generation',
      );

      await container
          .read(musicFavoritesProvider.notifier)
          .toggleTrack(track, grant: grant);

      expect(port.values, contains('entry-1'));
      expect(container.read(musicFavoritesProvider), contains('entry-1'));
    },
  );

  test(
    'switching the authorized root clears the prior root favorites',
    () async {
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
      final port = _FavoritesPort();
      final container = ProviderContainer(
        overrides: [musicFavoritesPortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      container.read(musicScanProvider);
      final roots = container.read(rootGrantProvider.notifier);
      roots.setGrant(oldGrant);
      await container
          .read(musicFavoritesProvider.notifier)
          .toggleTrack(
            const MusicTrack(
              id: 'entry-old',
              relativePath: 'song.mp3',
              size: 1,
              extension: 'mp3',
            ),
            grant: oldGrant,
          );
      expect(container.read(musicFavoritesProvider), contains('entry-old'));

      roots.setGrant(newGrant);

      expect(container.read(musicFavoritesProvider), isEmpty);
    },
  );
}
