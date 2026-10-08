import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/sync/local_store.dart';
import 'package:synctune/sync/sync_model.dart';

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
}
