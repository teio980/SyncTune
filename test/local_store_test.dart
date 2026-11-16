import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/sync/local_store.dart';
import 'package:synctune/sync/state_store.dart';
import 'package:synctune/sync/sync_model.dart';

import 'flac_test_data.dart';

void main() {
  late Directory root;
  late FileLocalStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synctune-local-');
    store = FileLocalStore(root.path);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('a matching partial stage resumes from its verified prefix', () async {
    const id = '12345678-1234-1234-1234-123456789abc';
    final content = utf8.encode('a streamed song payload');
    final partial = content.sublist(0, 8);
    final stageFile = File(
      '${root.path}${Platform.pathSeparator}.synctune-local-v2'
      '${Platform.pathSeparator}sync${Platform.pathSeparator}$id.part',
    );
    await stageFile.parent.create(recursive: true);
    await stageFile.writeAsBytes(partial);

    await store.stage(
      id,
      Stream<List<int>>.value(content),
      hashBytes(content),
      CancellationToken(),
    );

    expect(await store.stageHash(id, CancellationToken()), hashBytes(content));
  });

  test('commit refuses to overwrite an unknown recovery backup', () async {
    const id = '12345678-1234-1234-1234-123456789abc';
    final path = SyncPath.parse('Album/song.mp3');
    final target = File(
      '${root.path}${Platform.pathSeparator}Album'
      '${Platform.pathSeparator}song.mp3',
    );
    await target.parent.create(recursive: true);
    final previous = utf8.encode('previous song');
    final next = utf8.encode('new song');
    await target.writeAsBytes(previous);
    final backup = File(
      '${root.path}${Platform.pathSeparator}.synctune-local-v2'
      '${Platform.pathSeparator}sync${Platform.pathSeparator}$id.backup',
    );
    await backup.parent.create(recursive: true);
    await backup.writeAsString('unknown recovery data');
    await store.stage(
      id,
      Stream.value(next),
      hashBytes(next),
      CancellationToken(),
    );

    await expectLater(
      store.commit(
        path,
        id,
        id,
        hashBytes(next),
        hashBytes(previous),
        CancellationToken(),
      ),
      throwsA(isA<SyncFailure>()),
    );
    expect(await target.readAsBytes(), previous);
    expect(await backup.readAsString(), 'unknown recovery data');
  });

  test('scan reuses baseline hashes for unchanged MP3 and FLAC files', () async {
    final mp3 = File('${root.path}${Platform.pathSeparator}song.mp3');
    final flac = File('${root.path}${Platform.pathSeparator}song.flac');
    await mp3.writeAsString('mp3 bytes');
    final flacBytes = testFlac(['TITLE=Song', 'ARTIST=A']);
    await flac.writeAsBytes(flacBytes);

    final initial = await store.scan(CancellationToken());
    final mp3File = initial.files.singleWhere(
      (f) => f.path == SyncPath.parse('song.mp3'),
    );
    final flacFile = initial.files.singleWhere(
      (f) => f.path == SyncPath.parse('song.flac'),
    );
    expect(flacFile.comparisonHash, isNotNull);

    final baseline = <SyncPath, BaselineEntry>{
      for (final file in initial.files)
        file.path: BaselineEntry(
          path: file.path,
          sha256: file.sha256,
          localSize: file.size,
          localModifiedMs: file.modifiedMs,
          remoteEtag: '"e"',
          remoteSize: file.size,
          comparisonHash: file.comparisonHash,
        ),
    };

    var bytesRead = 0;
    final reused = await store.scan(
      CancellationToken(),
      baseline: baseline,
      onBytes: (_, bytes) => bytesRead += bytes,
    );
    expect(bytesRead, 0);
    expect(
      reused.files.singleWhere((f) => f.path == mp3File.path).sha256,
      mp3File.sha256,
    );
    final reusedFlac = reused.files.singleWhere((f) => f.path == flacFile.path);
    expect(reusedFlac.sha256, flacFile.sha256);
    expect(reusedFlac.comparisonHash, flacFile.comparisonHash);

    await mp3.setLastModified(DateTime(2025));
    bytesRead = 0;
    final afterMtimeChange = await store.scan(
      CancellationToken(),
      baseline: baseline,
      onBytes: (_, bytes) => bytesRead += bytes,
    );
    expect(bytesRead, mp3File.size);
    expect(
      afterMtimeChange.files.singleWhere((f) => f.path == mp3File.path).sha256,
      mp3File.sha256,
    );
  });

  test('scan checkpoints reuse FLAC comparison hashes across resumed scans', () async {
    final flac = File('${root.path}${Platform.pathSeparator}track.flac');
    await flac.writeAsBytes(testFlac(['TITLE=Track']));
    final state = SqliteStateStore(
      '${root.path}${Platform.pathSeparator}checkpoint.sqlite',
    );
    await state.open();
    addTearDown(state.close);

    var bytesRead = 0;
    final first = await store.scan(
      CancellationToken(),
      checkpoint: state.scanCheckpoint(reuse: false),
      onBytes: (_, bytes) => bytesRead += bytes,
    );
    expect(bytesRead, greaterThan(0));
    expect(first.files.single.comparisonHash, isNotNull);

    bytesRead = 0;
    final resumed = await store.scan(
      CancellationToken(),
      checkpoint: state.scanCheckpoint(reuse: true),
      onBytes: (_, bytes) => bytesRead += bytes,
    );
    expect(bytesRead, 0);
    expect(resumed.files.single.sha256, first.files.single.sha256);
    expect(
      resumed.files.single.comparisonHash,
      first.files.single.comparisonHash,
    );
  });
}
