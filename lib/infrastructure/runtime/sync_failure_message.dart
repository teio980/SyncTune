import 'dart:async';

import 'package:dio/dio.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';

import '../../data/webdav_repository.dart';
import '../platform/broker_local_object_store.dart';

/// App-owned diagnostic copy only; raw transport exceptions may carry secrets.
String syncFailureMessage(Object error) {
  if (error is RemoteMusicImportRequired) {
    return 'Existing cloud music needs to be imported into SyncTune. Tap Import cloud music, then sync again.';
  }
  if (error is WebDavHttpError) {
    return switch (error.status) {
      401 => 'Authentication failed. Check your username and password.',
      403 => 'Access denied. Check your account permissions for this folder.',
      404 => 'A required WebDAV file or folder was not found. Check the sync folder and retry.',
      405 || 501 => 'The server does not support a required WebDAV operation.',
      507 => 'The cloud storage is full. Free some space and retry.',
      _ => 'WebDAV request failed.\nHTTP ${error.status}\nTry again later.',
    };
  }
  if (error is WebDavCompatibilityError) {
    if (error.message.contains('ETag')) {
      return 'The server did not provide a strong file ETag. Safe sync is unavailable for this server.';
    }
    return 'The WebDAV response or SyncTune metadata is invalid. Check the sync folder and retry.';
  }
  if (error is TimeoutException) {
    return 'The connection timed out. Check the server and try again.';
  }
  if (error is DioException) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        'The connection timed out. Check the server and try again.',
      DioExceptionType.badCertificate =>
        'The server certificate could not be verified.',
      _ => 'Could not reach the WebDAV server. Check the URL and network.',
    };
  }
  if (error is BrokerError) {
    return 'Local folder access or file verification failed. Scan the music folder again and retry.';
  }
  if (error is RemotePreconditionFailed) {
    return 'A cloud file changed during sync. Check again and retry.';
  }
  if (error is NeedsRescan) {
    final reason = error.reason;
    if (reason is! String && !identical(reason, error)) {
      return syncFailureMessage(reason);
    }
    return 'File verification or the final sync check failed. Scan again and retry.';
  }
  return 'Sync failed. Check folder access and the sync settings, then retry.';
}

bool needsRemoteMusicImport(Object error) =>
    error is RemoteMusicImportRequired ||
    (error is NeedsRescan &&
        error.reason is! String &&
        !identical(error.reason, error) &&
        needsRemoteMusicImport(error.reason));
