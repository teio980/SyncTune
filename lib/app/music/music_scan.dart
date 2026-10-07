import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import '../../infrastructure/platform/music_scan_channel.dart';
import '../sync/sync_status_view_model.dart';

export '../../infrastructure/platform/music_scan_channel.dart'
    show musicScanChannel, musicScannerPortProvider;

final class MusicTrack {
  const MusicTrack({
    required this.relativePath,
    required this.size,
    required this.extension,
    this.id,
    this.favorite = false,
  });

  final String relativePath;
  final int size;
  final String extension;
  final String? id;
  final bool favorite;

  factory MusicTrack.fromMap(Map<Object?, Object?> value) {
    final path = value['relativePath']?.toString() ?? '';
    final sizeValue = value['size'];
    final extension = value['extension']?.toString().toLowerCase() ?? '';
    final idValue = value['id']?.toString();
    final id = idValue == null || idValue.isEmpty ? null : idValue;
    final favorite = value['favorite'] == true;
    final size = sizeValue is int ? sizeValue : null;
    final segments = path.split('/');
    const allowed = <String>{'mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'opus'};
    late final SyncPath parsedPath;
    try {
      parsedPath = SyncPath.parse(path);
    } on FormatException {
      throw const FormatException(
        'The native scan returned an invalid music entry',
      );
    }
    final lastSegment = parsedPath.segments.last;
    final dot = lastSegment.lastIndexOf('.');
    final actualExtension = dot > 0
        ? lastSegment.substring(dot + 1).toLowerCase()
        : '';
    if (path != parsedPath.value ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        ) ||
        !allowed.contains(extension) ||
        actualExtension != extension ||
        size == null ||
        size < 0) {
      throw const FormatException(
        'The native scan returned an invalid music entry',
      );
    }
    return MusicTrack(
      relativePath: path,
      size: size,
      extension: extension,
      id: id,
      favorite: favorite,
    );
  }
}

abstract interface class MusicFavoritesPort {
  Future<Set<String>> loadFavorites(RootGrant grant);

  Future<void> setFavorite({
    required RootGrant grant,
    required MusicTrack track,
    required bool value,
  });
}

final musicFavoritesPortProvider = Provider<MusicFavoritesPort?>((ref) => null);

final class MusicFavoritesMessageViewModel extends Notifier<String?> {
  @override
  String? build() => null;

  void setMessage(String? message) => state = message;
}

final musicFavoritesMessageProvider =
    NotifierProvider<MusicFavoritesMessageViewModel, String?>(
      MusicFavoritesMessageViewModel.new,
    );

enum MusicScanStatus { idle, loading, ready, failed }

final class MusicScanState {
  const MusicScanState({
    this.status = MusicScanStatus.idle,
    this.tracks = const <MusicTrack>[],
    this.error,
    this.generation,
    this.complete = false,
  });

  final MusicScanStatus status;
  final List<MusicTrack> tracks;
  final String? error;
  final String? generation;
  final bool complete;

  bool get isLoading => status == MusicScanStatus.loading;
}

class MusicScanController extends Notifier<MusicScanState> {
  int _request = 0;
  bool _disposed = false;

  @override
  MusicScanState build() {
    ref.listen<RootGrant?>(rootGrantProvider, (previous, next) {
      if (_disposed ||
          (previous?.generation == next?.generation &&
              previous?.token == next?.token)) {
        return;
      }
      _request++;
      state = const MusicScanState();
      ref.read(musicFavoritesProvider.notifier).clear();
    });
    ref.onDispose(() => _disposed = true);
    return const MusicScanState();
  }

  Future<void> scan(RootGrant grant) async {
    if (state.isLoading) return;
    final request = ++_request;
    final currentGrant = ref.read(rootGrantProvider);
    if (_disposed ||
        currentGrant?.token != grant.token ||
        currentGrant?.generation != grant.generation) {
      state = MusicScanState(
        status: MusicScanStatus.failed,
        generation: currentGrant?.generation ?? grant.generation,
        error: 'The authorized root folder has changed. Select it again before scanning.',
      );
      return;
    }
    state = MusicScanState(
      status: MusicScanStatus.loading,
      tracks: state.tracks,
      generation: grant.generation,
    );
    try {
      final result = await ref.read(musicScannerPortProvider).scan(grant);
      if (result['status'] != 'ok') {
        throw StateError(
          result['error']?.toString() ?? 'The music scan did not finish',
        );
      }
      final returnedGeneration = result['generation']?.toString() ?? '';
      if (returnedGeneration != grant.generation) {
        throw StateError(
          'The authorized root folder changed during the scan. Scan again.',
        );
      }
      final rawItems = result['items'];
      if (rawItems is! List) {
        throw const FormatException(
          'The native scan did not return an entry list',
        );
      }
      final tracks = <MusicTrack>[];
      for (final item in rawItems) {
        if (item is! Map<Object?, Object?>) {
          throw const FormatException(
            'The native scan contains an invalid music entry',
          );
        }
        tracks.add(MusicTrack.fromMap(item));
      }
      if (_disposed ||
          request != _request ||
          ref.read(rootGrantProvider)?.generation != grant.generation) {
        return;
      }
      state = MusicScanState(
        status: MusicScanStatus.ready,
        tracks: tracks,
        generation: returnedGeneration,
        complete: result['complete'] == true,
      );
      // A durable favorites port is authoritative. Native scan records may
      // omit favorites or contain a stale false value, so do not replace an
      // already loaded DB set with that transient projection. The page's
      // ready listener reloads the durable set for this generation.
      if (ref.read(musicFavoritesPortProvider) == null) {
        final scannedFavorites = tracks
            .where((track) => track.favorite)
            .map((track) => track.id ?? track.relativePath);
        ref
            .read(musicFavoritesProvider.notifier)
            .setFavorites(scannedFavorites);
      }
    } catch (error) {
      if (_disposed || request != _request) return;
      state = MusicScanState(
        status: MusicScanStatus.failed,
        tracks: const <MusicTrack>[],
        generation: grant.generation,
        error: '$error',
      );
    }
  }

  void clear() {
    _request++;
    state = const MusicScanState();
  }
}

final musicScanProvider = NotifierProvider<MusicScanController, MusicScanState>(
  MusicScanController.new,
);

/// UI-only favorite selection. Persistence is owned by the sync/data layer;
/// this provider keeps the list responsive while a scan is in progress.
final class MusicFavoritesViewModel extends Notifier<Set<String>> {
  int _epoch = 0;
  int _nextTrackRequest = 0;
  final Map<String, int> _trackRequests = <String, int>{};
  final Set<String> _failedTracks = <String>{};
  String? _rootKey;
  bool _disposed = false;

  @override
  Set<String> build() {
    ref.onDispose(() => _disposed = true);
    return <String>{};
  }

  Future<void> load(RootGrant grant) async {
    final epoch = ++_epoch;
    _rootKey = _grantKey(grant);
    _trackRequests.clear();
    _failedTracks.clear();
    final port = ref.read(musicFavoritesPortProvider);
    if (port == null) return;
    if (_disposed) return;
    state = <String>{};
    try {
      final values = await port.loadFavorites(grant);
      if (_disposed || epoch != _epoch) return;
      state = Set.unmodifiable(values);
      _setMessage(null);
    } catch (_) {
      if (_disposed || epoch != _epoch) return;
      _setMessage(
        'Could not load favorites. The displayed favorites may be incomplete.',
      );
    }
  }

  Future<void> toggleTrack(MusicTrack track, {required RootGrant grant}) async {
    final grantKey = _grantKey(grant);
    if (_rootKey != grantKey) {
      _epoch++;
      _rootKey = grantKey;
      _trackRequests.clear();
      _failedTracks.clear();
      state = <String>{};
    }
    final epoch = _epoch;
    final key = track.id ?? track.relativePath;
    final port = ref.read(musicFavoritesPortProvider);
    if (port == null || _disposed) return;
    final request = ++_nextTrackRequest;
    _trackRequests[key] = request;
    final value = !state.contains(key);
    final next = <String>{...state};
    if (value) {
      next.add(key);
    } else {
      next.remove(key);
    }
    state = Set.unmodifiable(next);
    try {
      await port.setFavorite(grant: grant, track: track, value: value);
      if (!_currentTrack(epoch, key, request)) return;
      _failedTracks.remove(key);
      _setMessage(
        _failedTracks.isEmpty
            ? null
            : 'Could not save favorites. Try again later.',
      );
    } catch (_) {
      if (!_currentTrack(epoch, key, request)) return;
      final rollback = <String>{...state};
      if (value) {
        rollback.remove(key);
      } else {
        rollback.add(key);
      }
      state = Set.unmodifiable(rollback);
      _failedTracks.add(key);
      _setMessage('Could not save favorites. Try again later.');
    }
  }

  void setFavorites(Iterable<String> values) {
    if (_disposed) return;
    _trackRequests.clear();
    _failedTracks.clear();
    state = Set.unmodifiable(values.toSet());
  }

  void clear() {
    _epoch++;
    _rootKey = null;
    _trackRequests.clear();
    _failedTracks.clear();
    if (_disposed) return;
    state = <String>{};
    _setMessage(null);
  }

  bool _currentTrack(int epoch, String key, int request) =>
      !_disposed && epoch == _epoch && _trackRequests[key] == request;

  void _setMessage(String? message) {
    if (_disposed) return;
    ref.read(musicFavoritesMessageProvider.notifier).setMessage(message);
  }

  String _grantKey(RootGrant grant) => '${grant.token}:${grant.generation}';
}

final musicFavoritesProvider =
    NotifierProvider<MusicFavoritesViewModel, Set<String>>(
      MusicFavoritesViewModel.new,
    );
