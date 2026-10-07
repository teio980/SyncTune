// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:synctune_sync_core/synctune_sync_core.dart';
import 'package:xml/xml.dart';

final class WebDavCompatibilityError extends NeedsRescan {
  const WebDavCompatibilityError(this.message) : super(message);
  final String message;

  @override
  String toString() => 'WebDAV compatibility error: $message';
}

final class WebDavResource {
  const WebDavResource({
    required this.path,
    required this.etag,
    required this.size,
    required this.modifiedAtUtc,
    required this.isCollection,
  });

  final SyncPath path;
  final String etag;
  final int size;
  final DateTime modifiedAtUtc;
  final bool isCollection;
}

final class WebDavReadResult {
  const WebDavReadResult({required this.stream, required this.etag});
  final Stream<List<int>> stream;
  final String etag;
}

/// Dio/XML WebDAV transport. It never derives a write condition implicitly:
/// callers must pass CreateOnly or a validated strong MatchEtag.
final class WebDavRepository implements RemoteRepository, RemotePlanRecovery {
  WebDavRepository({
    required Dio dio,
    required Uri baseUri,
    Duration requestTimeout = const Duration(seconds: 30),
  }) : _dio = dio,
       _baseUri = _validateBaseUri(baseUri) {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
    // Keep caller-provided tighter limits. Every request-specific Options
    // object below inherits these defaults from Dio's BaseOptions, so a
    // broken DAV server cannot hold a foreground sync indefinitely.
    _dio.options.connectTimeout ??= requestTimeout;
    _dio.options.sendTimeout ??= requestTimeout;
    _dio.options.receiveTimeout ??= requestTimeout;
  }

  final Dio _dio;
  final Uri _baseUri;

  /// Runs one Dio operation with both a transport-level CancelToken and a
  /// core-level race.  Some adapters honor Dio's cancel future, while a
  /// custom adapter may only complete its request later; the race makes the
  /// core operation finish as soon as its cancellation token fires in either
  /// case.  The request future still has an error handler attached so a late
  /// adapter error cannot become an unhandled asynchronous error.
  Future<T> _request<T>(
    CancellationToken token,
    Future<T> Function(CancelToken? cancelToken) send,
  ) {
    token.throwIfCancelled();
    final signal = token is CancellationSignal
        ? (token as CancellationSignal).onCancel
        : null;
    final dioToken = signal == null ? null : CancelToken();
    final result = Completer<T>();
    var settled = false;

    void completeError(Object error, StackTrace stack) {
      if (settled) return;
      settled = true;
      if (error is DioException &&
          (error.type == DioExceptionType.cancel || token.isCancelled)) {
        result.completeError(const SyncCancelled(), stack);
      } else {
        result.completeError(error, stack);
      }
    }

    void completeValue(T value) {
      if (settled) return;
      if (token.isCancelled) {
        completeError(const SyncCancelled(), StackTrace.current);
        return;
      }
      settled = true;
      result.complete(value);
    }

    try {
      final request = send(dioToken);
      request.then<void>(
        completeValue,
        onError: (Object error, StackTrace stack) {
          completeError(error, stack);
        },
      );
    } catch (error, stack) {
      completeError(error, stack);
    }

    if (signal != null) {
      signal.then<void>((_) {
        dioToken?.cancel();
        if (settled) return;
        completeError(const SyncCancelled(), StackTrace.current);
      }, onError: (Object ignoredError, StackTrace ignoredStack) {});
    }
    return result.future;
  }

  static Uri _validateBaseUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const WebDavCompatibilityError(
        'WebDAV requires an HTTPS endpoint without userinfo or URL extras.',
      );
    }
    final segments = uri.pathSegments.toList();
    if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
    if (segments.any((segment) {
      if (segment.isEmpty || segment == '.' || segment == '..') return true;
      try {
        final decoded = Uri.decodeComponent(segment);
        return decoded == '.' || decoded == '..';
      } on FormatException {
        return true;
      }
    })) {
      throw const WebDavCompatibilityError(
        'WebDAV endpoint path contains an unsafe segment.',
      );
    }
    final text = uri.toString();
    return text.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
  }

  /// Reconciles the narrow failure window where the content PUT succeeded but
  /// its descriptor CAS did not. This is intentionally driven by the durable
  /// plan and staged journal evidence, before a normal remote snapshot: a
  /// snapshot quite correctly rejects a live object whose descriptor hash is
  /// stale, so recovery must first prove the current bytes are the planned
  /// bytes and then CAS the descriptor against its newest strong ETag.
  @override
  Future<Set<String>> recoverPendingPlan(
    SyncRoot root,
    SyncPlan plan, {
    required Iterable<JournalRecord> journal,
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    if (root.id.isEmpty ||
        plan.generation != root.generation ||
        plan.remoteNamespace != root.remoteNamespace) {
      throw const NeedsRescan('pending remote recovery scope changed');
    }
    final records = <String, List<JournalRecord>>{};
    for (final record in journal) {
      if (record.planId != plan.planId ||
          record.generation != plan.generation) {
        throw const NeedsRescan(
          'pending remote recovery journal scope changed',
        );
      }
      (records[record.operationId] ??= <JournalRecord>[]).add(record);
    }
    final recovered = <String>{};
    for (final operation in plan.operations) {
      token.throwIfCancelled();
      final operationRecords = records[operation.id];
      if (operation.planId != plan.planId ||
          operation.generation != plan.generation ||
          (operationRecords == null &&
              operation.kind != SyncOperationKind.conflict)) {
        continue;
      }
      final currentRecords = operationRecords ?? const <JournalRecord>[];
      if (operation.kind == SyncOperationKind.putLocalToRemote &&
          operation.source?.kind == SyncEntryKind.file &&
          operation.source?.sha256 != null &&
          operation.metadataCondition != null) {
        final source = operation.source!;
        if (currentRecords.any(
          (record) => record.state == JournalState.committed,
        )) {
          continue;
        }
        JournalRecord? staged;
        for (final record in currentRecords.reversed) {
          if (record.state == JournalState.staged &&
              record.stagingKey != null) {
            staged = record;
            break;
          }
        }
        final stagedRecord = staged;
        if (stagedRecord == null ||
            stagedRecord.path != operation.path ||
            stagedRecord.sha256 != source.sha256 ||
            stagedRecord.length != source.size ||
            stagedRecord.condition != operation.condition?.fingerprint ||
            stagedRecord.metadataCondition !=
                operation.metadataCondition?.fingerprint) {
          continue;
        }
        final contentEtag = await headEtag(operation.path, token: token);
        if (contentEtag == null) continue;
        final content = await readWithEtag(
          operation.path,
          token: token,
          ifMatch: contentEtag,
        );
        if (content == null) continue;
        final actual = await _hashReadResult(content, token);
        if (content.etag != contentEtag ||
            actual.length != source.size ||
            actual.sha256 != source.sha256) {
          throw NeedsRescan('pending content changed for ${operation.path}');
        }

        final metadata = await _readDescriptorForRecovery(
          operation.path,
          token: token,
          allowMissing: true,
        );
        token.throwIfCancelled();
        if (metadata == null) {
          if (operation.metadataCondition is! CreateOnly) continue;
          await putMetadata(
            operation.path,
            source,
            condition: const CreateOnly(),
            token: token,
          );
          recovered.add(operation.id);
          continue;
        }
        final descriptorIsSource = _sameDescriptorFields(
          metadata.entry,
          source,
        );
        if (descriptorIsSource) {
          recovered.add(operation.id);
          continue;
        }
        final previous = operation.other;
        if (previous == null ||
            !_sameDescriptorFields(metadata.entry, previous)) {
          // A different descriptor writer won the race. Do not overwrite it
          // or infer identity from the content hash; a fresh reconciliation is
          // required instead.
          throw NeedsRescan('pending descriptor changed for ${operation.path}');
        }
        final expectedMetadata = operation.metadataCondition;
        if (expectedMetadata is! MatchEtag) {
          throw NeedsRescan(
            'pending descriptor condition changed for ${operation.path}',
          );
        }
        final mergedSource = source.copyWith(
          favorite: source.favorite.merge(metadata.entry.favorite),
        );
        await putMetadata(
          operation.path,
          mergedSource,
          // The old ETag identifies the descriptor expected by the plan. A
          // byte-for-byte rewrite can legitimately give it a fresh ETag, so
          // CAS the latest verified strong ETag after comparing all fields.
          condition: MatchEtag(metadata.etag),
          token: token,
        );
        recovered.add(operation.id);
        continue;
      }

      if (operation.kind == SyncOperationKind.deleteRemote) {
        if (operation.source?.kind != SyncEntryKind.tombstone ||
            operation.condition is! MatchEtag ||
            operation.metadataCondition is! MatchEtag ||
            currentRecords.any(
              (record) => record.state == JournalState.committed,
            )) {
          continue;
        }
        final intent = currentRecords.lastWhere(
          (record) => record.state == JournalState.staged,
          orElse: () =>
              throw const NeedsRescan('pending delete has no durable intent'),
        );
        if (intent.path != operation.path ||
            intent.condition != operation.condition?.fingerprint ||
            intent.metadataCondition !=
                operation.metadataCondition?.fingerprint) {
          throw const NeedsRescan('pending delete intent changed');
        }
        final contentEtag = await headEtag(operation.path, token: token);
        if (contentEtag != null) {
          final expectedContent = operation.condition! as MatchEtag;
          if (contentEtag != expectedContent.etag) {
            throw NeedsRescan(
              'pending delete content changed for ${operation.path}',
            );
          }
          await delete(
            operation.path,
            condition: expectedContent,
            tombstone: operation.source,
            metadataCondition: operation.metadataCondition,
            token: token,
          );
          recovered.add(operation.id);
          continue;
        }
        final metadata = await _readDescriptorForRecovery(
          operation.path,
          token: token,
          allowMissing: true,
        );
        if (metadata == null) {
          throw NeedsRescan(
            'pending delete lost both content and descriptor for ${operation.path}',
          );
        }
        if (_sameDescriptorFields(metadata.entry, operation.source!)) {
          recovered.add(operation.id);
          continue;
        }
        final previous = operation.other;
        if (previous == null ||
            !_sameDescriptorFields(metadata.entry, previous)) {
          throw NeedsRescan(
            'pending delete descriptor changed for ${operation.path}',
          );
        }
        final mergedTombstone = operation.source!.copyWith(
          favorite: operation.source!.favorite.merge(metadata.entry.favorite),
        );
        await putMetadata(
          operation.path,
          mergedTombstone,
          condition: MatchEtag(metadata.etag),
          token: token,
        );
        recovered.add(operation.id);
        continue;
      }

      if (operation.kind == SyncOperationKind.conflict) {
        final conflictRecovered = await _recoverConflictRemoteSteps(
          operation,
          records,
          token,
        );
        recovered.addAll(conflictRecovered);
      }
    }
    return recovered;
  }

  Future<Set<String>> _recoverConflictRemoteSteps(
    SyncOperation operation,
    Map<String, List<JournalRecord>> records,
    CancellationToken token,
  ) async {
    final primary = operation.source;
    final secondary = operation.other;
    final preservePath = operation.preservePath;
    if (primary == null ||
        secondary == null ||
        preservePath == null ||
        operation.sourceIsLocal == null ||
        primary.kind != SyncEntryKind.file ||
        secondary.kind != SyncEntryKind.file ||
        primary.sha256 == null ||
        secondary.sha256 == null ||
        primary.path != operation.path ||
        secondary.path != preservePath) {
      throw const NeedsRescan(
        'pending conflict recovery metadata is incomplete',
      );
    }

    final recovered = <String>{};
    Future<void> recoverPut({
      required String step,
      required SyncPath target,
      required SyncEntry desired,
      required RemoteCondition contentCondition,
      required RemoteCondition metadataCondition,
      required SyncEntry? previous,
    }) async {
      token.throwIfCancelled();
      conditionalHeaders(contentCondition);
      conditionalHeaders(metadataCondition);
      final commitId = conflictCheckpointId(operation, step);
      final commitRecords = records[commitId];
      if (commitRecords == null) return;
      if (commitRecords.any(
        (record) => record.state == JournalState.committed,
      )) {
        return;
      }
      final intent = commitRecords.lastWhere(
        (record) => record.state == JournalState.staged,
        orElse: () => throw NeedsRescan(
          'pending conflict step $step has no durable intent',
        ),
      );
      if (intent.planId != operation.planId ||
          intent.generation != operation.generation ||
          intent.path != target) {
        throw NeedsRescan('pending conflict step $step scope changed');
      }

      final stageId = conflictCheckpointId(
        operation,
        step == 'remote-primary' ? 'stage-primary' : 'stage-secondary',
      );
      final stageRecords = records[stageId];
      final stage = stageRecords?.lastWhere(
        (record) => record.state == JournalState.staged,
        orElse: () => throw NeedsRescan(
          'pending conflict step $step has no staged bytes',
        ),
      );
      if (stage == null ||
          stage.planId != operation.planId ||
          stage.generation != operation.generation ||
          stage.stagingKey == null ||
          stage.sha256 != desired.sha256 ||
          stage.length != desired.size) {
        throw NeedsRescan('pending conflict step $step bytes are unverified');
      }
      final expectedStagePath =
          step == 'remote-primary' || operation.sourceIsLocal == true
          ? operation.path
          : preservePath;
      if (stage.path != expectedStagePath) {
        throw NeedsRescan('pending conflict stage path changed for $target');
      }

      final contentEtag = await headEtag(target, token: token);
      token.throwIfCancelled();
      if (contentEtag == null) {
        throw NeedsRescan('pending conflict content is missing at $target');
      }
      final content = await readWithEtag(
        target,
        token: token,
        ifMatch: contentEtag,
      );
      if (content == null) {
        throw NeedsRescan('pending conflict content disappeared at $target');
      }
      final actual = await _hashReadResult(content, token);
      if (content.etag != contentEtag ||
          actual.sha256 != desired.sha256 ||
          actual.length != desired.size) {
        throw NeedsRescan('pending conflict content changed at $target');
      }

      final metadata = await _readDescriptorForRecovery(
        target,
        token: token,
        allowMissing: true,
      );
      token.throwIfCancelled();
      if (metadata == null) {
        if (metadataCondition is CreateOnly) {
          await putMetadata(
            target,
            desired,
            condition: const CreateOnly(),
            token: token,
          );
          recovered.add(commitId);
          return;
        }
        throw NeedsRescan('pending conflict descriptor is missing at $target');
      }
      if (_sameDescriptorFields(metadata.entry, desired)) {
        recovered.add(commitId);
        return;
      }
      if (previous == null ||
          !_sameDescriptorFields(metadata.entry, previous)) {
        throw NeedsRescan('pending conflict descriptor changed at $target');
      }
      final merged = desired.copyWith(
        favorite: desired.favorite.merge(metadata.entry.favorite),
      );
      // The descriptor may have been rewritten after the original plan was
      // captured. CAS the latest strong ETag after proving its full prior
      // descriptor, never the stale plan ETag and never an unconditional PUT.
      await putMetadata(
        target,
        merged,
        condition: MatchEtag(metadata.etag),
        token: token,
      );
      recovered.add(commitId);
    }

    if (operation.sourceIsLocal == true) {
      final contentCondition = operation.condition;
      final metadataCondition = operation.metadataCondition;
      if (contentCondition == null || metadataCondition == null) {
        throw const NeedsRescan('pending conflict CAS conditions are missing');
      }
      await recoverPut(
        step: 'remote-primary',
        target: operation.path,
        desired: primary,
        contentCondition: contentCondition,
        metadataCondition: metadataCondition,
        previous: operation.remoteBefore,
      );
    }
    await recoverPut(
      step: 'remote-preserve',
      target: preservePath,
      desired: secondary,
      contentCondition: const CreateOnly(),
      metadataCondition: const CreateOnly(),
      previous: null,
    );
    return recovered;
  }

  bool _sameDescriptorFields(SyncEntry left, SyncEntry right) =>
      left.id == right.id &&
      left.path == right.path &&
      left.kind == right.kind &&
      left.size == right.size &&
      left.sha256 == right.sha256 &&
      left.revision == right.revision &&
      left.modifiedAtUtc.toUtc() == right.modifiedAtUtc.toUtc();

  Future<_EntryMetadata?> _readDescriptorForRecovery(
    SyncPath path, {
    required CancellationToken token,
    bool allowMissing = false,
  }) async {
    final documentResult = await readWithEtag(
      _entryMetadataPath(path),
      token: token,
      allowMissing: allowMissing,
    );
    token.throwIfCancelled();
    if (documentResult == null) {
      if (allowMissing) return null;
      throw WebDavCompatibilityError(
        'Missing identity metadata for ${path.value}.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in documentResult.stream) {
      token.throwIfCancelled();
      bytes.addAll(chunk);
      if (bytes.length > 256 * 1024) {
        throw const WebDavCompatibilityError(
          'Identity metadata document exceeded its size limit.',
        );
      }
    }
    token.throwIfCancelled();
    final document = XmlDocument.parse(utf8.decode(bytes));
    final root = document.rootElement;
    if (root.name.local != 'entry' ||
        root.name.namespaceUri != 'urn:synctune:v1') {
      throw const WebDavCompatibilityError('Invalid entry metadata document.');
    }
    String requiredAttribute(String name) {
      final value = root.getAttribute(name);
      if (value == null || value.isEmpty) {
        throw WebDavCompatibilityError('Missing metadata attribute $name.');
      }
      return value;
    }

    final id = requiredAttribute('id');
    final metadataPath = SyncPath.parse(requiredAttribute('path'));
    if (metadataPath != path) {
      throw WebDavCompatibilityError(
        'Metadata path does not match ${path.value}.',
      );
    }
    final modified = DateTime.tryParse(requiredAttribute('modifiedAtUtc'));
    final revision = int.tryParse(requiredAttribute('revision'));
    final size = int.tryParse(requiredAttribute('size'));
    final favoriteRaw = requiredAttribute('favorite');
    final favoriteLamport = int.tryParse(requiredAttribute('favoriteLamport'));
    final favoriteDevice = root.getAttribute('favoriteDevice');
    if (modified == null ||
        revision == null ||
        revision < 0 ||
        size == null ||
        size < 0 ||
        favoriteLamport == null ||
        favoriteLamport < 0 ||
        favoriteDevice == null ||
        (favoriteRaw != 'true' && favoriteRaw != 'false')) {
      throw const WebDavCompatibilityError('Invalid entry metadata values.');
    }
    final favorite = FavoriteStamp(
      value: favoriteRaw == 'true',
      lamport: favoriteLamport,
      deviceId: favoriteDevice,
    );
    final kind = requiredAttribute('kind');
    final entry = switch (kind) {
      'file' => SyncEntry.file(
        id: id,
        path: path,
        size: size,
        modifiedAtUtc: modified,
        sha256: requiredAttribute('sha256'),
        revision: revision,
        favorite: favorite,
      ),
      'directory' => SyncEntry.directory(
        id: id,
        path: path,
        modifiedAtUtc: modified,
        revision: revision,
        favorite: favorite,
      ),
      'tombstone' => SyncEntry.tombstone(
        id: id,
        path: path,
        modifiedAtUtc: modified,
        revision: revision,
        favorite: favorite,
      ),
      _ => throw WebDavCompatibilityError('Unknown metadata kind $kind.'),
    };
    return _EntryMetadata(entry: entry, etag: documentResult.etag);
  }

  Uri _resourceUri(SyncPath path) {
    final segments = path.segments.map(Uri.encodeComponent).join('/');
    return _baseUri.resolve(segments);
  }

  static Map<String, String> conditionalHeaders(RemoteCondition condition) {
    return switch (condition) {
      CreateOnly() => const <String, String>{'If-None-Match': '*'},
      MatchEtag(:final etag) => <String, String>{'If-Match': etag},
      RemoteCondition() => throw const WebDavCompatibilityError(
        'Unsupported remote write condition.',
      ),
    };
  }

  static void _requireSuccess(Response<dynamic> response, SyncPath path) {
    final status = response.statusCode ?? 0;
    if (status == 412) throw RemotePreconditionFailed(path);
    if (status < 200 || status >= 300) {
      throw WebDavCompatibilityError('HTTP $status for $path.');
    }
  }

  static void _requireStatus(
    Response<dynamic> response,
    SyncPath path,
    Set<int> accepted,
  ) {
    final status = response.statusCode ?? 0;
    if (status == 412) throw RemotePreconditionFailed(path);
    if (!accepted.contains(status)) {
      throw WebDavCompatibilityError('HTTP $status for $path.');
    }
  }

  static Future<void> _requireDeleteSuccess(
    Response<dynamic> response,
    SyncPath path,
  ) async {
    final status = response.statusCode ?? 0;
    if (status == 412) throw RemotePreconditionFailed(path);
    if (status != 207) {
      _requireStatus(response, path, const {200, 202, 204});
      return;
    }
    final body = await _responseText(response.data);
    if (body == null || body.isEmpty) {
      throw const WebDavCompatibilityError(
        'DELETE multistatus response had no body.',
      );
    }
    final document = XmlDocument.parse(body);
    final root = document.rootElement;
    if (root.name.local != 'multistatus' || root.name.namespaceUri != 'DAV:') {
      throw const WebDavCompatibilityError(
        'DELETE 207 response is not a DAV multistatus.',
      );
    }
    final responses = root.children.whereType<XmlElement>().where(
      (element) =>
          element.name.local == 'response' &&
          element.name.namespaceUri == 'DAV:',
    );
    var count = 0;
    for (final item in responses) {
      count++;
      final itemStatus = _childText(item, 'status');
      if (itemStatus == null ||
          !RegExp(r'^HTTP/\d(?:\.\d)?\s+2\d\d\b').hasMatch(itemStatus.trim())) {
        throw WebDavCompatibilityError(
          'DELETE member failed: ${itemStatus ?? 'missing status'}.',
        );
      }
    }
    if (count == 0) {
      throw const WebDavCompatibilityError(
        'DELETE multistatus response had no members.',
      );
    }
  }

  static Future<String?> _responseText(Object? body) async {
    if (body is String) return body;
    if (body is List<int>) return utf8.decode(body);
    if (body is ResponseBody) {
      final chunks = await body.stream.toList();
      return utf8.decode(chunks.expand((chunk) => chunk).toList());
    }
    return null;
  }

  Future<List<WebDavResource>> propfind(
    SyncPath directory, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    final result = await _propfindAt(
      _resourceUri(directory),
      parseBaseUri: _baseUri,
      token: token,
    );
    if (result == null) {
      throw WebDavCompatibilityError('Missing PROPFIND resource $directory.');
    }
    return result;
  }

  Future<List<WebDavResource>?> propfindIfExists(
    SyncPath directory, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    return _propfindAt(
      _resourceUri(directory),
      parseBaseUri: _baseUri,
      token: token,
      allowMissing: true,
    );
  }

  /// Lists the configured DAV root. The root itself has no SyncPath because
  /// an empty relative path is intentionally invalid in the core model.
  Future<List<WebDavResource>> propfindRoot({
    CancellationToken token = const NeverCancelled(),
  }) async {
    final result = await _propfindAt(
      _baseUri,
      parseBaseUri: _baseUri,
      token: token,
    );
    if (result == null) {
      throw const WebDavCompatibilityError('Missing WebDAV root.');
    }
    return result;
  }

  Future<String?> headEtag(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final response = await _request<Response<dynamic>>(
      token,
      (cancelToken) => _dio.headUri<dynamic>(
        _resourceUri(path),
        options: Options(
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      ),
    );
    if (response.statusCode == 404) return null;
    _requireStatus(response, path, const {200});
    return _strongEtag(response.headers.value('etag'), path);
  }

  Future<List<WebDavResource>?> _propfindAt(
    Uri uri, {
    required CancellationToken token,
    required Uri parseBaseUri,
    bool allowMissing = false,
  }) async {
    token.throwIfCancelled();
    final response = await _request<Response<String>>(
      token,
      (cancelToken) => _dio.requestUri<String>(
        uri,
        options: Options(
          method: 'PROPFIND',
          responseType: ResponseType.plain,
          headers: const <String, String>{
            'Depth': '1',
            'Content-Type': 'application/xml; charset=utf-8',
          },
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      ),
    );
    if (allowMissing && response.statusCode == 404) return null;
    final label = SyncPath.parse('.synctune-propfind');
    _requireSuccess(response, label);
    final body = response.data;
    if (body == null || body.isEmpty) {
      throw const WebDavCompatibilityError('Empty PROPFIND response.');
    }
    return parsePropfind(body, baseUri: parseBaseUri);
  }

  Future<void> mkcol(
    SyncPath directory, {
    RemoteCondition condition = const CreateOnly(),
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final response = await _request<Response<dynamic>>(
      token,
      (cancelToken) => _dio.requestUri<dynamic>(
        _resourceUri(directory),
        options: Options(
          method: 'MKCOL',
          headers: conditionalHeaders(condition),
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status == 405) {
      // Servers commonly use 405 for an existing collection. Verify the
      // resource instead of treating every 405 as success: a DAV file at the
      // requested path must never be mistaken for a collection.
      final resources = await propfindIfExists(directory, token: token);
      token.throwIfCancelled();
      if (resources == null ||
          !resources.any(
            (resource) => resource.path == directory && resource.isCollection,
          )) {
        throw WebDavCompatibilityError(
          'MKCOL returned 405 but $directory is not a collection.',
        );
      }
      return;
    }
    _requireStatus(response, directory, const {201});
  }

  /// Creates every missing parent collection in order. Real WebDAV servers
  /// reject PUT into a nested path when any parent is absent, while the
  /// in-memory test transport is permissive. Each MKCOL remains conditional;
  /// an existing collection is accepted only after a PROPFIND verifies it.
  Future<void> _ensureParentCollections(
    SyncPath path, {
    required CancellationToken token,
  }) async {
    final segments = path.segments;
    if (segments.length < 2) return;
    for (var length = 1; length < segments.length; length++) {
      token.throwIfCancelled();
      await mkcol(
        SyncPath.parse(segments.take(length).join('/')),
        token: token,
      );
      token.throwIfCancelled();
    }
  }

  /// Explicitly attaches SyncTune identity metadata to an existing music
  /// object. Ordinary DAV files are never adopted during a background scan;
  /// the caller must supply the stable identity and complete hash after an
  /// explicit user action. The descriptor is create-only by default so a
  /// concurrent adoption cannot be overwritten silently.
  Future<void> adoptExistingFile(
    SyncEntry entry, {
    RemoteCondition metadataCondition = const CreateOnly(),
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    if (entry.kind != SyncEntryKind.file || entry.sha256 == null) {
      throw const WebDavCompatibilityError(
        'Only a hashed file can be explicitly adopted.',
      );
    }
    if (metadataCondition is! CreateOnly) {
      throw const WebDavCompatibilityError(
        'Explicit adoption requires create-only identity metadata CAS.',
      );
    }
    final resources = await propfind(entry.path, token: token);
    if (resources.length != 1) {
      throw WebDavCompatibilityError(
        'DAV adoption returned an unexpected resource count for ${entry.path}.',
      );
    }
    final resource = resources.single;
    if (resource.isCollection || resource.size != entry.size) {
      throw WebDavCompatibilityError(
        'DAV adoption metadata does not match ${entry.path}.',
      );
    }
    final content = await readWithEtag(
      entry.path,
      token: token,
      ifMatch: resource.etag,
    );
    if (content == null) {
      throw WebDavCompatibilityError(
        'DAV adoption content disappeared for ${entry.path}.',
      );
    }
    final actual = await _hashReadResult(content, token);
    if (content.etag != resource.etag ||
        actual.length != entry.size ||
        actual.sha256 != entry.sha256) {
      throw NeedsRescan(
        'DAV adoption content changed or hash disagrees for ${entry.path}.',
      );
    }
    conditionalHeaders(metadataCondition);
    await putMetadata(
      entry.path,
      entry,
      condition: metadataCondition,
      token: token,
    );
  }

  @override
  Future<Stream<List<int>>> read(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final result = await readWithEtag(path, token: token);
    if (result == null) {
      throw const WebDavCompatibilityError('Empty GET body.');
    }
    return result.stream;
  }

  Future<WebDavReadResult?> readWithEtag(
    SyncPath path, {
    CancellationToken token = const NeverCancelled(),
    bool allowMissing = false,
    String? ifMatch,
  }) async {
    token.throwIfCancelled();
    final response = await _request<Response<ResponseBody>>(
      token,
      (cancelToken) => _dio.getUri<ResponseBody>(
        _resourceUri(path),
        options: Options(
          responseType: ResponseType.stream,
          headers: ifMatch == null ? null : {'If-Match': ifMatch},
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      ),
    );
    if (allowMissing && response.statusCode == 404) return null;
    _requireStatus(response, path, const {200});
    final body = response.data;
    if (body == null) throw const WebDavCompatibilityError('Empty GET body.');
    return WebDavReadResult(
      stream: _cancelableStream(body.stream, token),
      etag: _strongEtag(response.headers.value('etag'), path),
    );
  }

  @override
  Future<String> put(
    SyncPath path,
    Stream<List<int>> content, {
    required SyncEntry entry,
    required RemoteCondition condition,
    required RemoteCondition metadataCondition,
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    await _ensureParentCollections(path, token: token);
    token.throwIfCancelled();
    final response = await _request<Response<dynamic>>(
      token,
      (cancelToken) => _dio.putUri<dynamic>(
        _resourceUri(path),
        data: content.map((chunk) {
          token.throwIfCancelled();
          return chunk;
        }),
        options: Options(
          contentType: 'application/octet-stream',
          headers: conditionalHeaders(condition),
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      ),
    );
    _requireStatus(response, path, const {200, 201, 204});
    final etag = _strongEtag(response.headers.value('etag'), path);
    try {
      await putMetadata(
        path,
        entry,
        condition: metadataCondition,
        token: token,
      );
    } catch (error) {
      // The content object is already committed. Do not continue a stale
      // operation after its identity metadata CAS failed.
      if (error is RemotePreconditionFailed ||
          error is WebDavCompatibilityError ||
          error is SyncCancelled) {
        throw NeedsRescan('content committed but metadata CAS failed: $error');
      }
      throw NeedsRescan('content committed but metadata CAS failed: $error');
    }
    return etag;
  }

  static SyncPath _entryMetadataPath(SyncPath path) => SyncPath.parse(
    '.synctune/entries/${Uri.encodeComponent(path.value)}.xml',
  );

  static SyncPath _favoriteMetadataPath(SyncPath path) => SyncPath.parse(
    '.synctune/favorites/${Uri.encodeComponent(path.value)}.xml',
  );

  /// Writes the identity/fingerprint metadata as a separate CAS object. The
  /// caller must supply that object's own ETag for an update.
  Future<String> putMetadata(
    SyncPath path,
    SyncEntry entry, {
    required RemoteCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    if (entry.path != path) {
      throw const WebDavCompatibilityError(
        'Identity metadata path does not match the content path.',
      );
    }
    final metadataPath = _entryMetadataPath(path);
    await _ensureParentCollections(metadataPath, token: token);
    token.throwIfCancelled();
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'entry',
      attributes: <String, String>{
        'xmlns': 'urn:synctune:v1',
        'id': entry.id,
        'path': entry.path.value,
        'kind': entry.kind.name,
        'size': '${entry.size}',
        'modifiedAtUtc': entry.modifiedAtUtc.toIso8601String(),
        'revision': '${entry.revision}',
        'favorite': entry.favorite.value.toString(),
        'favoriteLamport': '${entry.favorite.lamport}',
        'favoriteDevice': entry.favorite.deviceId,
        if (entry.sha256 != null) 'sha256': entry.sha256!,
      },
    );
    final response = await _request<Response<dynamic>>(
      token,
      (cancelToken) => _dio.putUri<dynamic>(
        _resourceUri(metadataPath),
        data: Stream<List<int>>.value(
          utf8.encode(builder.buildDocument().toXmlString()),
        ),
        options: Options(
          contentType: 'application/xml',
          headers: conditionalHeaders(condition),
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      ),
    );
    _requireStatus(response, metadataPath, const {200, 201, 204});
    return _strongEtag(response.headers.value('etag'), metadataPath);
  }

  @override
  Future<void> delete(
    SyncPath path, {
    required MatchEtag condition,
    SyncEntry? tombstone,
    RemoteCondition? metadataCondition,
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    // Validate every mutation precondition before sending DELETE. A content
    // delete without a durable tombstone would make the item eligible for
    // resurrection on the next snapshot, so the pair is all-or-nothing at
    // the transport boundary.
    if ((tombstone == null) != (metadataCondition == null)) {
      throw const WebDavCompatibilityError(
        'Content deletion requires a matching tombstone metadata condition.',
      );
    }
    if (tombstone != null) {
      if (tombstone.path != path || !tombstone.isDeleted) {
        throw const WebDavCompatibilityError(
          'Delete tombstone must match the deleted path and be a tombstone.',
        );
      }
      // Force validation of the condition before the content request. This
      // keeps unsupported future condition types from mutating remote state.
      conditionalHeaders(metadataCondition!);
    }
    final response = await _request<Response<dynamic>>(
      token,
      (cancelToken) => _dio.deleteUri<dynamic>(
        _resourceUri(path),
        options: Options(
          headers: conditionalHeaders(condition),
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      ),
    );
    await _requireDeleteSuccess(response, path);
    if (tombstone != null) {
      try {
        await putMetadata(
          path,
          tombstone,
          condition: metadataCondition!,
          token: token,
        );
      } catch (error) {
        throw NeedsRescan(
          'content deleted but tombstone metadata CAS failed: $error',
        );
      }
    }
  }

  @override
  Future<void> updateFavorite(
    SyncPath path,
    FavoriteStamp stamp, {
    required RemoteCondition condition,
    CancellationToken token = const NeverCancelled(),
  }) async {
    token.throwIfCancelled();
    final metadataPath = _favoriteMetadataPath(path);
    await _ensureParentCollections(metadataPath, token: token);
    token.throwIfCancelled();
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'favorite',
      attributes: <String, String>{
        'xmlns': 'urn:synctune:v1',
        'value': stamp.value.toString(),
        'lamport': '${stamp.lamport}',
        'device': stamp.deviceId,
      },
    );
    final body = utf8.encode(builder.buildDocument().toXmlString());
    final response = await _request<Response<dynamic>>(
      token,
      (cancelToken) => _dio.putUri<dynamic>(
        _resourceUri(metadataPath),
        data: Stream<List<int>>.value(body),
        options: Options(
          contentType: 'application/xml',
          headers: conditionalHeaders(condition),
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      ),
    );
    _requireStatus(response, metadataPath, const {200, 201, 204});
    _strongEtag(response.headers.value('etag'), metadataPath);
  }

  static String _strongEtag(String? value, SyncPath path) {
    if (value == null) {
      throw WebDavCompatibilityError('Missing strong ETag for $path.');
    }
    try {
      MatchEtag(value);
    } on FormatException {
      throw WebDavCompatibilityError('Weak or invalid ETag for $path.');
    }
    return value;
  }

  static List<WebDavResource> parsePropfind(String xml, {Uri? baseUri}) {
    final document = XmlDocument.parse(xml);
    final root = document.rootElement;
    if (root.name.local != 'multistatus' || root.name.namespaceUri != 'DAV:') {
      throw const WebDavCompatibilityError(
        'PROPFIND is not a DAV multistatus.',
      );
    }
    final resources = <WebDavResource>[];
    final seen = <String>{};
    for (final response in root.children.whereType<XmlElement>().where(
      (element) =>
          element.name.local == 'response' &&
          element.name.namespaceUri == 'DAV:',
    )) {
      final href = _childText(response, 'href');
      if (href == null) {
        throw const WebDavCompatibilityError('PROPFIND omitted href metadata.');
      }
      final successfulProps = <XmlElement>[];
      for (final propstat in response.children.whereType<XmlElement>().where(
        (element) =>
            element.name.local == 'propstat' &&
            element.name.namespaceUri == 'DAV:',
      )) {
        final status = _childText(propstat, 'status');
        if (status != null &&
            RegExp(r'^HTTP/\d(?:\.\d)?\s+2\d\d\b').hasMatch(status.trim())) {
          final prop = propstat.children
              .whereType<XmlElement>()
              .where(
                (element) =>
                    element.name.local == 'prop' &&
                    element.name.namespaceUri == 'DAV:',
              )
              .firstOrNull;
          if (prop != null) successfulProps.add(prop);
        }
      }
      if (successfulProps.isEmpty) {
        throw const WebDavCompatibilityError(
          'PROPFIND resource has no 2xx propstat.',
        );
      }
      final hrefUri = Uri.tryParse(href);
      if (hrefUri == null) {
        throw const WebDavCompatibilityError('PROPFIND href was invalid.');
      }
      if (hrefUri.path.split('/').any((segment) {
        if (segment == '.' || segment == '..') return true;
        try {
          final decoded = Uri.decodeComponent(segment);
          return decoded == '.' || decoded == '..';
        } on FormatException {
          return true;
        }
      })) {
        throw const WebDavCompatibilityError(
          'PROPFIND href contained raw traversal.',
        );
      }
      if (baseUri != null &&
          (hrefUri.hasScheme || hrefUri.host.isNotEmpty) &&
          (hrefUri.scheme != baseUri.scheme ||
              hrefUri.host != baseUri.host ||
              hrefUri.port != baseUri.port ||
              hrefUri.userInfo != baseUri.userInfo)) {
        throw const WebDavCompatibilityError(
          'PROPFIND href escaped to another host.',
        );
      }
      final uri = baseUri?.resolveUri(hrefUri) ?? hrefUri;
      if (baseUri != null &&
          (uri.scheme != baseUri.scheme ||
              uri.host != baseUri.host ||
              uri.port != baseUri.port ||
              uri.userInfo != baseUri.userInfo)) {
        throw const WebDavCompatibilityError(
          'PROPFIND href escaped to another host.',
        );
      }
      // A collection href conventionally ends in '/', which Dart exposes as
      // one trailing empty path segment. Remove only that terminator. Empty
      // segments in the middle of a path remain invalid and are rejected
      // below rather than being silently normalized.
      final segments = uri.pathSegments.toList();
      var trailingEmptyCount = 0;
      while (trailingEmptyCount < segments.length &&
          segments[segments.length - 1 - trailingEmptyCount].isEmpty) {
        trailingEmptyCount++;
      }
      if (trailingEmptyCount > 1) {
        throw const WebDavCompatibilityError(
          'PROPFIND href contained multiple collection terminators.',
        );
      }
      while (segments.isNotEmpty && segments.last.isEmpty) {
        segments.removeLast();
      }
      final prefix = baseUri == null
          ? const <String>[]
          : baseUri.pathSegments
                .toList()
                .where((segment) => segment.isNotEmpty)
                .toList();
      if (segments.length < prefix.length ||
          !_samePathPrefix(segments, prefix)) {
        throw const WebDavCompatibilityError(
          'PROPFIND href escaped the DAV root.',
        );
      }
      final relativeSegments = segments.sublist(prefix.length);
      if (relativeSegments.isEmpty) continue;
      if (relativeSegments.any(
        (segment) => segment.isEmpty || segment == '.' || segment == '..',
      )) {
        throw const WebDavCompatibilityError(
          'PROPFIND href contained traversal or an empty path segment.',
        );
      }
      final path = SyncPath.parse(relativeSegments.join('/'));
      if (!seen.add(path.value)) {
        throw WebDavCompatibilityError('Duplicate PROPFIND path: $path');
      }
      final etag = _propertyText(successfulProps, 'getetag');
      final collection = successfulProps.any(
        (prop) => prop.children.whereType<XmlElement>().any(
          (element) =>
              element.name.local == 'resourcetype' &&
              element.name.namespaceUri == 'DAV:' &&
              element.children.whereType<XmlElement>().any(
                (child) =>
                    child.name.local == 'collection' &&
                    child.name.namespaceUri == 'DAV:',
              ),
        ),
      );
      final sizeText = _propertyText(successfulProps, 'getcontentlength');
      final modifiedText = _propertyText(successfulProps, 'getlastmodified');
      final size = sizeText == null
          ? (collection ? 0 : null)
          : int.tryParse(sizeText);
      final modified = modifiedText == null
          ? (collection
                ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
                : null)
          : (DateTime.tryParse(modifiedText) ?? HttpDate.parse(modifiedText));
      if (etag == null || size == null || size < 0 || modified == null) {
        throw const WebDavCompatibilityError('PROPFIND metadata was invalid.');
      }
      _strongEtag(etag, path);
      resources.add(
        WebDavResource(
          path: path,
          etag: etag,
          size: size,
          modifiedAtUtc: modified.toUtc(),
          isCollection: collection,
        ),
      );
    }
    return resources;
  }

  static bool _samePathPrefix(List<String> path, List<String> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (path[i] != prefix[i]) return false;
    }
    return true;
  }

  static String? _childText(XmlElement parent, String localName) {
    for (final child in parent.children.whereType<XmlElement>()) {
      if (child.name.local == localName && child.name.namespaceUri == 'DAV:') {
        return child.innerText;
      }
    }
    return null;
  }

  static String? _propertyText(
    Iterable<XmlElement> properties,
    String localName,
  ) {
    String? value;
    for (final prop in properties) {
      final current = _childText(prop, localName);
      if (current == null) continue;
      if (value != null && value != current) {
        throw const WebDavCompatibilityError(
          'PROPFIND returned conflicting successful properties.',
        );
      }
      value = current;
    }
    return value;
  }
}

/// Remote snapshot adapter for the core coordinator. It walks only resources
/// returned by broker-equivalent WebDAV PROPFIND calls and requires the
/// companion identity metadata before exposing a file to the planner.
final class WebDavRemoteSnapshotProvider implements RemoteSnapshotProvider {
  WebDavRemoteSnapshotProvider({required WebDavRepository repository})
    : _repository = repository;

  final WebDavRepository _repository;

  static const _musicExtensions = <String>{
    'mp3',
    'flac',
    'wav',
    'm4a',
    'aac',
    'ogg',
    'opus',
  };

  @override
  Future<RemoteSnapshot> capture(
    SyncRoot root, {
    CancellationToken token = const NeverCancelled(),
  }) async {
    final entries = <SyncPath, RemoteObject>{};
    final pending = <SyncPath>[];
    final visited = <SyncPath>{};
    final first = await _repository.propfindRoot(token: token);
    await _consume(first, entries, pending, token);
    while (pending.isNotEmpty) {
      token.throwIfCancelled();
      final directory = pending.removeAt(0);
      if (_isMetadataPath(directory)) continue;
      if (!visited.add(directory)) continue;
      if (visited.length > 1024 || directory.segments.length > 64) {
        throw const WebDavCompatibilityError(
          'WebDAV collection traversal exceeded its safety limit.',
        );
      }
      final resources = await _repository.propfind(directory, token: token);
      await _consume(resources, entries, pending, token);
    }
    await _consumeEntryMetadata(entries, token);
    return RemoteSnapshot(
      entries: entries,
      completeness: ScanCompleteness.complete,
      generation: root.generation,
      capturedAtUtc: DateTime.now().toUtc(),
    );
  }

  Future<void> _consume(
    Iterable<WebDavResource> resources,
    Map<SyncPath, RemoteObject> entries,
    List<SyncPath> pending,
    CancellationToken token,
  ) async {
    for (final resource in resources) {
      token.throwIfCancelled();
      if (_isMetadataPath(resource.path)) continue;
      if (resource.isCollection) {
        pending.add(resource.path);
        continue;
      }
      final dot = resource.path.value.lastIndexOf('.');
      if (dot < 0 ||
          !_musicExtensions.contains(
            resource.path.value.substring(dot + 1).toLowerCase(),
          )) {
        continue;
      }
      if (entries.length >= 10000 && !entries.containsKey(resource.path)) {
        throw const WebDavCompatibilityError(
          'WebDAV snapshot exceeded its item safety limit.',
        );
      }
      final metadata = (await _readEntryMetadata(resource.path, token: token))!;
      if (metadata.entry.kind != SyncEntryKind.file ||
          metadata.entry.size != resource.size) {
        throw WebDavCompatibilityError(
          'Content and identity metadata disagree for ${resource.path}.',
        );
      }
      final content = await _repository.readWithEtag(
        resource.path,
        token: token,
        ifMatch: resource.etag,
      );
      if (content == null) {
        throw WebDavCompatibilityError(
          'Content disappeared while reading ${resource.path}.',
        );
      }
      final actual = await _hashReadResult(content, token);
      if (content.etag != resource.etag) {
        throw NeedsRescan(
          'Content ETag changed while reading ${resource.path}.',
        );
      }
      if (actual.length != metadata.entry.size ||
          actual.sha256 != metadata.entry.sha256) {
        throw NeedsRescan(
          'Content hash disagrees with identity metadata for ${resource.path}.',
        );
      }
      entries[resource.path] = RemoteObject(
        entry: metadata.entry,
        etag: content.etag,
        metadataEtag: metadata.etag,
        favoriteEtag: metadata.favoriteEtag,
      );
    }
  }

  Future<void> _consumeEntryMetadata(
    Map<SyncPath, RemoteObject> entries,
    CancellationToken token,
  ) async {
    final root = await _repository.propfindIfExists(
      SyncPath.parse('.synctune/entries'),
      token: token,
    );
    if (root == null) return;
    final pending = <SyncPath>[];
    final visited = <SyncPath>{};
    pending.addAll(
      root
          .where((resource) => resource.isCollection)
          .map((resource) => resource.path),
    );
    final resources = [...root.where((resource) => !resource.isCollection)];
    while (pending.isNotEmpty) {
      token.throwIfCancelled();
      final directory = pending.removeAt(0);
      if (!visited.add(directory)) continue;
      if (visited.length > 1024) {
        throw const WebDavCompatibilityError(
          'WebDAV metadata traversal exceeded its safety limit.',
        );
      }
      final children = await _repository.propfind(directory, token: token);
      pending.addAll(
        children
            .where((resource) => resource.isCollection)
            .map((resource) => resource.path),
      );
      resources.addAll(children.where((resource) => !resource.isCollection));
      if (resources.length > 10000) {
        throw const WebDavCompatibilityError(
          'WebDAV metadata exceeded its item safety limit.',
        );
      }
    }
    if (resources.length > 10000) {
      throw const WebDavCompatibilityError(
        'WebDAV metadata exceeded its item safety limit.',
      );
    }
    for (final resource in resources) {
      final path = _logicalPathFromEntryMetadata(resource.path);
      final metadata = (await _readEntryMetadata(path, token: token))!;
      final current = entries[path];
      if (current != null &&
          !current.entry.isDeleted &&
          !metadata.entry.isDeleted &&
          (!metadata.entry.contentEquals(current.entry) ||
              metadata.etag != current.metadataEtag)) {
        // The content was hashed against the descriptor seen during the
        // first walk. A descriptor replacement between those reads must stop
        // the run; otherwise a new hash/identity could be paired with the
        // old content ETag and incorrectly become a confirmed baseline.
        throw NeedsRescan(
          'Identity metadata changed while scanning ${path.value}.',
        );
      }
      if (metadata.entry.isDeleted && current != null) {
        // A Depth-1 listing can race the content DELETE. Confirm the live
        // object itself before treating the pair as an ambiguous protocol
        // state; a 404 means the tombstone is the authoritative remaining
        // record, while a live object still requires a fresh reconciliation.
        final liveEtag = await _repository.headEtag(path, token: token);
        if (liveEtag != null) {
          throw WebDavCompatibilityError(
            'Live content conflicts with a tombstone for ${path.value}.',
          );
        }
        entries.remove(path);
      }
      if (!metadata.entry.isDeleted && current == null) {
        throw WebDavCompatibilityError(
          'Identity metadata has no live content for ${path.value}.',
        );
      }
      if (metadata.entry.isDeleted) {
        entries[path] = RemoteObject(
          entry: metadata.entry,
          etag: current?.etag,
          metadataEtag: metadata.etag,
          favoriteEtag: metadata.favoriteEtag,
        );
      } else if (current != null) {
        entries[path] = RemoteObject(
          entry: metadata.entry,
          etag: current.etag,
          metadataEtag: metadata.etag,
          favoriteEtag: metadata.favoriteEtag,
        );
      }
    }
  }

  SyncPath _logicalPathFromEntryMetadata(SyncPath metadataPath) {
    const prefix = '.synctune/entries/';
    if (!metadataPath.value.startsWith(prefix) ||
        !metadataPath.value.endsWith('.xml')) {
      throw WebDavCompatibilityError(
        'Unexpected identity metadata path ${metadataPath.value}.',
      );
    }
    final encoded = metadataPath.value.substring(
      prefix.length,
      metadataPath.value.length - '.xml'.length,
    );
    try {
      return SyncPath.parse(Uri.decodeComponent(encoded));
    } on FormatException {
      rethrow;
    } catch (error) {
      throw WebDavCompatibilityError(
        'Invalid identity metadata path ${metadataPath.value}: $error',
      );
    }
  }

  Future<_EntryMetadata?> _readEntryMetadata(
    SyncPath path, {
    required CancellationToken token,
    bool allowMissing = false,
  }) async {
    final documentResult = await _repository.readWithEtag(
      WebDavRepository._entryMetadataPath(path),
      token: token,
      allowMissing: allowMissing,
    );
    if (documentResult == null) {
      if (allowMissing) return null;
      throw WebDavCompatibilityError(
        'Missing identity metadata for ${path.value}.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in documentResult.stream) {
      token.throwIfCancelled();
      bytes.addAll(chunk);
      if (bytes.length > 256 * 1024) {
        throw const WebDavCompatibilityError(
          'Identity metadata document exceeded its size limit.',
        );
      }
    }
    final document = XmlDocument.parse(utf8.decode(bytes));
    final root = document.rootElement;
    if (root.name.local != 'entry' ||
        root.name.namespaceUri != 'urn:synctune:v1') {
      throw const WebDavCompatibilityError('Invalid entry metadata document.');
    }
    String requiredAttribute(String name) {
      final value = root.getAttribute(name);
      if (value == null || value.isEmpty) {
        throw WebDavCompatibilityError('Missing metadata attribute $name.');
      }
      return value;
    }

    final id = requiredAttribute('id');
    final metadataPath = SyncPath.parse(requiredAttribute('path'));
    if (metadataPath != path) {
      throw WebDavCompatibilityError(
        'Metadata path does not match ${path.value}.',
      );
    }
    final kind = requiredAttribute('kind');
    final modified = DateTime.tryParse(requiredAttribute('modifiedAtUtc'));
    final revision = int.tryParse(requiredAttribute('revision'));
    final size = int.tryParse(requiredAttribute('size'));
    final favoriteValue = requiredAttribute('favorite');
    final favoriteLamport = int.tryParse(requiredAttribute('favoriteLamport'));
    final favoriteDevice = root.getAttribute('favoriteDevice');
    if (modified == null ||
        revision == null ||
        revision < 0 ||
        size == null ||
        size < 0 ||
        favoriteLamport == null ||
        favoriteLamport < 0 ||
        favoriteDevice == null ||
        (favoriteValue != 'true' && favoriteValue != 'false')) {
      throw const WebDavCompatibilityError('Invalid entry metadata values.');
    }
    final favorite = FavoriteStamp(
      value: favoriteValue == 'true',
      lamport: favoriteLamport,
      deviceId: favoriteDevice,
    );
    final entry = switch (kind) {
      'file' => SyncEntry.file(
        id: id,
        path: path,
        size: size,
        modifiedAtUtc: modified,
        sha256: requiredAttribute('sha256'),
        revision: revision,
        favorite: favorite,
      ),
      'directory' => SyncEntry.directory(
        id: id,
        path: path,
        modifiedAtUtc: modified,
        revision: revision,
        favorite: favorite,
      ),
      'tombstone' => SyncEntry.tombstone(
        id: id,
        path: path,
        modifiedAtUtc: modified,
        revision: revision,
        favorite: favorite,
      ),
      _ => throw WebDavCompatibilityError('Unknown metadata kind $kind.'),
    };
    final favoriteResult = await _repository.readWithEtag(
      WebDavRepository._favoriteMetadataPath(path),
      token: token,
      allowMissing: true,
    );
    if (favoriteResult == null) {
      return _EntryMetadata(entry: entry, etag: documentResult.etag);
    }
    final favoriteBytes = <int>[];
    await for (final chunk in favoriteResult.stream) {
      token.throwIfCancelled();
      favoriteBytes.addAll(chunk);
      if (favoriteBytes.length > 64 * 1024) {
        throw const WebDavCompatibilityError(
          'Favorite metadata document exceeded its size limit.',
        );
      }
    }
    final favoriteDocument = XmlDocument.parse(utf8.decode(favoriteBytes));
    final favoriteRoot = favoriteDocument.rootElement;
    if (favoriteRoot.name.local != 'favorite' ||
        favoriteRoot.name.namespaceUri != 'urn:synctune:v1') {
      throw const WebDavCompatibilityError(
        'Invalid favorite metadata document.',
      );
    }
    final favoriteRaw = favoriteRoot.getAttribute('value');
    final lamportRaw = favoriteRoot.getAttribute('lamport');
    final device = favoriteRoot.getAttribute('device');
    final lamport = lamportRaw == null ? null : int.tryParse(lamportRaw);
    if ((favoriteRaw != 'true' && favoriteRaw != 'false') ||
        lamport == null ||
        lamport < 0 ||
        device == null ||
        device.isEmpty) {
      throw const WebDavCompatibilityError('Invalid favorite metadata values.');
    }
    final mergedEntry = entry.copyWith(
      favorite: FavoriteStamp(
        value: favoriteRaw == 'true',
        lamport: lamport,
        deviceId: device,
      ),
    );
    return _EntryMetadata(
      entry: mergedEntry,
      etag: documentResult.etag,
      favoriteEtag: favoriteResult.etag,
    );
  }

  bool _isMetadataPath(SyncPath path) =>
      path.value == '.synctune' || path.value.startsWith('.synctune/');
}

final class _HashedReadResult {
  const _HashedReadResult({required this.sha256, required this.length});

  final String sha256;
  final int length;
}

final class _DigestAccumulator implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest value) {
    if (digest != null) throw StateError('digest already completed');
    digest = value;
  }

  @override
  void close() {
    if (digest == null) throw StateError('digest was not produced');
  }
}

Future<_HashedReadResult> _hashReadResult(
  WebDavReadResult result,
  CancellationToken token,
) async {
  final accumulator = _DigestAccumulator();
  final converter = sha256.startChunkedConversion(accumulator);
  var length = 0;
  await for (final chunk in result.stream) {
    token.throwIfCancelled();
    converter.add(chunk);
    length += chunk.length;
  }
  converter.close();
  final digest = accumulator.digest;
  if (digest == null) throw StateError('digest was not produced');
  return _HashedReadResult(sha256: digest.toString(), length: length);
}

/// Checking cancellation only when a chunk arrives leaves a consumer stuck
/// forever if the server stops delivering bytes. Race each pending read with
/// the optional runtime signal so a stalled response exits promptly.
Stream<List<int>> _cancelableStream(
  Stream<List<int>> source,
  CancellationToken token,
) async* {
  token.throwIfCancelled();
  final signal = token is CancellationSignal
      ? (token as CancellationSignal).onCancel
      : null;
  if (signal == null) {
    await for (final chunk in source) {
      token.throwIfCancelled();
      yield chunk;
    }
    return;
  }

  final iterator = StreamIterator<List<int>>(source);
  try {
    while (true) {
      final next = Completer<bool>();
      var settled = false;
      iterator.moveNext().then<void>(
        (value) {
          if (settled) return;
          settled = true;
          next.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (settled) return;
          settled = true;
          next.completeError(error, stack);
        },
      );
      signal.then<void>((_) {
        if (settled) return;
        settled = true;
        unawaited(iterator.cancel());
        next.completeError(const SyncCancelled(), StackTrace.current);
      }, onError: (Object ignoredError, StackTrace ignoredStack) {});
      if (!await next.future) return;
      token.throwIfCancelled();
      yield iterator.current;
    }
  } finally {
    await iterator.cancel();
  }
}

final class _EntryMetadata {
  const _EntryMetadata({
    required this.entry,
    required this.etag,
    this.favoriteEtag,
  });
  final SyncEntry entry;
  final String etag;
  final String? favoriteEtag;
}

extension on Iterable<XmlElement> {
  XmlElement? get firstOrNull => isEmpty ? null : first;
}
