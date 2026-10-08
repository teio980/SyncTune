import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/sync/sync_model.dart';
import 'package:synctune/sync/sync_planner.dart';

void main() {
  const planner = SyncPlanner();
  final baseline = <SyncPath, BaselineEntry>{
    _path('Album/song.mp3'): BaselineEntry(
      path: _path('Album/song.mp3'),
      sha256: _hash('old'),
      localModifiedMs: 1,
      remoteEtag: '"old-tag"',
      remoteSize: 3,
    ),
  };

  test('first sync copies each one-sided song without inferring deletion', () {
    final local = <SyncPath, SyncFile>{
      _path('Phone/one.mp3'): _file('Phone/one.mp3', 'one'),
    };
    final remote = <SyncPath, SyncFile>{
      _path('Cloud/two.flac'): _file('Cloud/two.flac', 'two'),
    };

    final plan = planner.plan(
      local: local,
      remote: remote,
      baseline: const <SyncPath, BaselineEntry>{},
    );

    expect(plan, hasLength(2));
    expect(
      plan.map((item) => item.sha256),
      containsAll(<String>[_hash('one'), _hash('two')]),
    );
    expect(plan.every((item) => item.sha256 != null), isTrue);
  });

  test('first sync preserves both versions of same-path different content', () {
    final path = _path('Album/song.mp3');
    final plan = planner.plan(
      local: <SyncPath, SyncFile>{path: _file(path.value, 'phone')},
      remote: <SyncPath, SyncFile>{path: _file(path.value, 'cloud')},
      baseline: const <SyncPath, BaselineEntry>{},
    );

    expect(plan, hasLength(2));
    expect(plan.first.sourceSide, ContentSide.local);
    expect(plan.first.path.value, contains('SyncTune conflict'));
    expect(plan.last.path, path);
    expect(plan.last.sha256, _hash('cloud'));
  });

  test('only one changed side wins and deletion beats a remote edit', () {
    final path = _path('Album/song.mp3');
    final localEdit = planner.plan(
      local: <SyncPath, SyncFile>{path: _file(path.value, 'phone edit')},
      remote: <SyncPath, SyncFile>{path: _file(path.value, 'old')},
      baseline: baseline,
    );
    expect(localEdit.single.sha256, _hash('phone edit'));
    expect(localEdit.single.sourceSide, ContentSide.local);

    final deletion = planner.plan(
      local: const <SyncPath, SyncFile>{},
      remote: <SyncPath, SyncFile>{path: _file(path.value, 'cloud edit')},
      baseline: baseline,
    );
    expect(deletion.single.sha256, isNull);
  });

  test(
    'two different edits keep the remote original and a local conflict copy',
    () {
      final path = _path('Album/song.mp3');
      final plan = planner.plan(
        local: <SyncPath, SyncFile>{path: _file(path.value, 'phone edit')},
        remote: <SyncPath, SyncFile>{path: _file(path.value, 'cloud edit')},
        baseline: baseline,
      );

      expect(plan, hasLength(2));
      expect(plan.first.sha256, _hash('phone edit'));
      expect(plan.first.sourcePath, path);
      expect(plan.last.path, path);
      expect(plan.last.sha256, _hash('cloud edit'));
    },
  );

  test('Windows path validation rejects intermediate case and file-directory collisions', () {
    expect(
      () => indexFiles(<SyncFile>[
        _file('Album/one.mp3', 'one'),
        _file('album/two.mp3', 'two'),
      ], windowsCaseSensitive: false),
      throwsA(isA<SyncFailure>()),
    );
    expect(
      () => indexFiles(<SyncFile>[
        _file('Album.mp3', 'file'),
        _file('Album/song.mp3', 'song'),
      ], windowsCaseSensitive: false),
      throwsA(isA<SyncFailure>()),
    );
  });
}

SyncPath _path(String value) => SyncPath.parse(value);

String _hash(String value) => hashBytes(value.codeUnits);

SyncFile _file(String path, String content) =>
    SyncFile(path: _path(path), sha256: _hash(content), size: content.length);
