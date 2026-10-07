import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/app/localization/strings.dart';
import 'package:flutter/material.dart';
import 'package:synctune/data/webdav_repository.dart';
import 'package:synctune/infrastructure/runtime/sync_failure_message.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

void main() {
  test('remote file failures distinguish version, truncation and hash', () {
    expect(
      syncFailureMessage(
        const RemoteFileVerificationFailed(RemoteFileMismatch.etag),
      ),
      contains('version'),
    );
    final message = syncFailureMessage(
      const RemoteFileVerificationFailed(
        RemoteFileMismatch.length,
        expected: 3000,
        actual: 1200,
      ),
    );
    expect(message, contains('Expected bytes: 3000'));
    expect(message, contains('Received bytes: 1200'));
    expect(
      const SyncTuneStrings(Locale('zh')).text(message),
      contains('已接收字节数：1200'),
    );
    expect(
      syncFailureMessage(
        const RemoteFileVerificationFailed(RemoteFileMismatch.hash),
      ),
      contains('saved sync record'),
    );
  });
  test('missing remote identity is distinct from an unreachable server', () {
    final error = RemoteMusicImportRequired(SyncPath.parse('song.mp3'));
    expect(needsRemoteMusicImport(error), isTrue);
    expect(needsRemoteMusicImport(NeedsRescan(error)), isTrue);
    final message = syncFailureMessage(NeedsRescan(error));
    expect(message, contains('Import cloud music'));
    expect(
      const SyncTuneStrings(Locale('zh')).text(message),
      contains('导入云端已有音乐'),
    );
  });

  test('HTTP status and transport failures keep private data out of copy', () {
    expect(
      syncFailureMessage(WebDavHttpError(403, SyncPath.parse('song.mp3'))),
      contains('Access denied'),
    );
    expect(
      syncFailureMessage(WebDavHttpError(500, SyncPath.parse('song.mp3'))),
      contains('HTTP 500'),
    );
    final error = DioException(
      requestOptions: RequestOptions(
        path: 'https://private.example/',
        headers: {'Authorization': 'Basic private-secret'},
      ),
      message: 'private-secret',
      type: DioExceptionType.receiveTimeout,
    );
    expect(syncFailureMessage(NeedsRescan(error)), contains('timed out'));
    expect(syncFailureMessage(error), isNot(contains('private')));
    expect(needsRemoteMusicImport(error), isFalse);
  });
}
