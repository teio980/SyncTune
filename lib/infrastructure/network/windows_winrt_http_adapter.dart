import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';

import '../platform/broker_local_object_store.dart';

/// Dio adapter backed by the packaged Windows.Web.Http broker.
///
/// Sync request bodies are staged through the authorized root's
/// `.synctune-local` broker session; small settings checks use an app-private
/// staging file. Windows streams the staged object into HttpStreamContent;
/// response bodies are read back through bounded MethodChannel chunks.
final class WindowsWinRtHttpAdapter implements HttpClientAdapter {
  WindowsWinRtHttpAdapter({required this.channel, this.root});

  static int _nextRequest = 0;

  final BrokerMethodChannel channel;
  final BrokerRootPort? root;
  final Set<String> _active = <String>{};
  final Set<String> _temporaryFiles = <String>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) {
      throw StateError('Windows HTTP adapter is closed.');
    }
    final requestId = _newRequestId();
    _BodyReference? body;
    var cancelled = false;
    _active.add(requestId);
    cancelFuture?.then((_) {
      cancelled = true;
      unawaited(_cancel(requestId));
    });
    try {
      body = await _writeRequestBody(
        options,
        requestStream,
        requestId,
        cancelFuture,
      );
      if (cancelled) throw _cancelled(options);
      final requestArguments = <String, Object?>{
        'id': requestId,
        'url': options.uri.toString(),
        'method': options.method,
        'headers': await _requestHeaders(options, body),
        'followRedirects': options.followRedirects,
        'maxRedirects': options.maxRedirects,
        'timeoutMs': _nativeOpenTimeout(options).inMilliseconds,
      };
      if (body?.path != null) requestArguments['bodyPath'] = body!.path;
      if (body?.key != null) requestArguments['bodyKey'] = body!.key;
      if (body?.token != null) requestArguments['token'] = body!.token;
      if (body?.generation != null) {
        requestArguments['generation'] = body!.generation;
      }
      final response = await channel
          .invokeMethod<Object?>('webdavOpen', requestArguments)
          .timeout(
            _openTimeout(options),
            onTimeout: () => throw _timedOut(options),
          );
      final map = _map(response);
      if (_text(map['id']) != requestId) {
        throw StateError('Windows HTTP response had an unexpected request id.');
      }
      if (cancelled) {
        await _cancel(requestId);
        throw _cancelled(options);
      }
      final statusCode = _int(map['statusCode']);
      if (statusCode == null) {
        throw StateError('Windows HTTP response did not contain a status.');
      }
      final headers = _responseHeaders(map['headers']);
      return ResponseBody(
        _readResponse(requestId, options),
        statusCode,
        statusMessage: _text(map['statusMessage']),
        headers: headers,
        onClose: () => unawaited(_close(requestId)),
      );
    } catch (_) {
      await _cancel(requestId);
      rethrow;
    } finally {
      final path = body?.path;
      if (path != null) await _deleteTemporary(path);
      if (body?.key != null) await _cleanupRootBody(body!);
    }
  }

  Stream<Uint8List> _readResponse(String id, RequestOptions options) async* {
    final timeout = _readTimeout(options);
    try {
      while (true) {
        final raw = await channel
            .invokeMethod<Object?>('webdavRead', <String, Object?>{
              'id': id,
              'maxBytes': 64 * 1024,
              'timeoutMs': timeout.inMilliseconds,
            })
            .timeout(timeout, onTimeout: () => throw _timedOut(options));
        final map = _map(raw);
        final bytes = _bytes(map['bytes']);
        if (bytes.isNotEmpty) yield bytes;
        if (map['eof'] == true) break;
      }
    } finally {
      await _close(id);
    }
  }

  Future<_BodyReference?> _writeRequestBody(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    String requestId,
    Future<void>? cancelFuture,
  ) async {
    final data = requestStream == null ? options.data : null;
    if (requestStream == null && data == null) return null;
    final currentRoot = root?.current;
    if (currentRoot != null) {
      return _stageAuthorizedBody(
        requestStream: requestStream,
        data: data,
        requestId: requestId,
        cancelFuture: cancelFuture,
        grant: currentRoot,
        options: options,
      );
    }
    final dbPath = await channel
        .invokeMethod<String>('privateDatabasePath')
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw _timedOut(options),
        );
    if (dbPath == null || dbPath.isEmpty) {
      throw StateError('Private HTTP staging path is unavailable.');
    }
    final file = File(
      '${File(dbPath).parent.path}${Platform.pathSeparator}'
      'synctune-webdav-$requestId.part',
    );
    var completed = false;
    IOSink? sink;
    try {
      await file.create(exclusive: true);
      _temporaryFiles.add(file.path);
      sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      if (requestStream != null) {
        await _addRequestStream(sink, requestStream, cancelFuture, options);
      } else if (data is Uint8List) {
        sink.add(data);
      } else if (data is List<int>) {
        sink.add(data);
      } else if (data is String) {
        sink.add(utf8.encode(data));
      } else {
        throw StateError('Unsupported Windows HTTP request body type.');
      }
      await sink.flush();
      await sink.close();
      completed = true;
    } finally {
      if (sink != null && !completed) {
        try {
          await sink.close();
        } catch (_) {
          // The original body error is more useful than a cleanup error.
        }
      }
      if (!completed) await _deleteTemporary(file.path);
    }
    return _BodyReference.path(file.path);
  }

  static DioException _cancelled(RequestOptions options) =>
      DioException.requestCancelled(
        requestOptions: options,
        reason: 'Request cancelled.',
      );

  static DioException _timedOut(RequestOptions options) => DioException(
    requestOptions: options,
    type: DioExceptionType.connectionTimeout,
    message: 'Windows HTTP request timed out.',
  );

  Future<void> _addRequestStream(
    IOSink sink,
    Stream<Uint8List> source,
    Future<void>? cancelFuture,
    RequestOptions options,
  ) async {
    // StreamIterator pauses the source between chunks; flushing each bounded
    // chunk applies the file sink's backpressure without collecting the whole
    // upload in memory.
    final iterator = StreamIterator<Uint8List>(source);
    var cancelled = false;
    final cancellation = cancelFuture?.then<void>((_) {
      cancelled = true;
      unawaited(_cancelIterator(iterator));
    });
    try {
      while (await _moveNextOrCancel(iterator, cancellation)) {
        if (cancelled) throw _cancelled(options);
        final chunk = iterator.current;
        for (var start = 0; start < chunk.length; start += 64 * 1024) {
          if (cancelled) throw _cancelled(options);
          final end = (start + 64 * 1024).clamp(0, chunk.length);
          sink.add(chunk.sublist(start, end));
          await sink.flush();
        }
      }
    } finally {
      await _cancelIterator(iterator);
      // Do not await a cancellation callback that is waiting for this body
      // operation to finish. It is deliberately fire-and-forget cleanup.
      unawaited(cancellation);
    }
  }

  static String _newRequestId() {
    final sequence = ++_nextRequest;
    return '${DateTime.now().microsecondsSinceEpoch}-$sequence';
  }

  Future<void> _cancel(String id) async {
    if (!_active.contains(id)) return;
    try {
      await channel.invokeMethod<Object?>('webdavCancel', <String, Object?>{
        'id': id,
      });
    } finally {
      _active.remove(id);
    }
  }

  Future<void> _close(String id) async {
    if (!_active.remove(id)) return;
    await channel.invokeMethod<Object?>('webdavClose', <String, Object?>{
      'id': id,
    });
  }

  Future<void> _deleteTemporary(String path) async {
    if (!_temporaryFiles.remove(path)) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // App-private cleanup is best effort; the next staging allocation uses
      // a unique name and no user file is exposed.
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final id in _active.toList()) {
      unawaited(_cancel(id));
    }
    for (final path in _temporaryFiles.toList()) {
      unawaited(_deleteTemporary(path));
    }
  }

  static Map<String, String> _headers(Map<String, dynamic> input) {
    return <String, String>{
      for (final entry in input.entries)
        entry.key: entry.value is List
            ? (entry.value as List).join(', ')
            : '${entry.value}',
    };
  }

  static Future<Map<String, String>> _requestHeaders(
    RequestOptions options,
    _BodyReference? body,
  ) async {
    final headers = _headers(options.headers);
    if (!headers.keys.any((key) => key.toLowerCase() == 'content-length')) {
      final length = body?.length;
      if (length != null) {
        headers['Content-Length'] = '$length';
      } else if (body?.path case final path?) {
        headers['Content-Length'] = '${await File(path).length()}';
      }
    }
    return headers;
  }

  Future<_BodyReference> _stageAuthorizedBody({
    required Stream<Uint8List>? requestStream,
    required Object? data,
    required String requestId,
    required Future<void>? cancelFuture,
    required BrokerRoot grant,
    required RequestOptions options,
  }) async {
    final started = _map(
      await channel.invokeMethod<Object?>('localStageBegin', <String, Object?>{
        'token': grant.token,
        'generation': grant.generation,
        'path': 'webdav-upload-$requestId',
      }),
    );
    final key = _text(started['key']);
    if (key == null) {
      throw StateError('WebDAV root staging did not return a key.');
    }
    final digestSink = _DigestSink();
    final digestInput = sha256.startChunkedConversion(digestSink);
    var offset = 0;
    var cancelled = false;
    final bodyStream =
        requestStream ??
        switch (data) {
          Uint8List value => Stream<Uint8List>.value(value),
          List<int> value => Stream<Uint8List>.value(Uint8List.fromList(value)),
          String value => Stream<Uint8List>.value(
            Uint8List.fromList(utf8.encode(value)),
          ),
          _ => throw StateError('Unsupported Windows HTTP request body type.'),
        };
    final iterator = StreamIterator<Uint8List>(bodyStream);
    final cancellation = cancelFuture?.then<void>((_) {
      cancelled = true;
      unawaited(_cancelIterator(iterator));
    });

    void ensureStagingIsCurrent() {
      final current = root?.current;
      if (cancelled ||
          current?.token != grant.token ||
          current?.generation != grant.generation) {
        throw _cancelled(options);
      }
    }

    Future<void> writeChunk(Uint8List chunk) async {
      for (var start = 0; start < chunk.length; start += 64 * 1024) {
        ensureStagingIsCurrent();
        final end = (start + 64 * 1024).clamp(0, chunk.length);
        final part = chunk.sublist(start, end);
        digestInput.add(part);
        final result = _map(
          await channel.invokeMethod<Object?>(
            'localStageWrite',
            <String, Object?>{
              'token': grant.token,
              'generation': grant.generation,
              'key': key,
              'offset': offset,
              'bytes': part,
            },
          ),
        );
        ensureStagingIsCurrent();
        final next = _int(result['nextOffset']);
        if (next == null || next != offset + part.length) {
          throw StateError(
            'WebDAV root staging returned a non-contiguous offset.',
          );
        }
        offset = next;
      }
    }

    try {
      while (await _moveNextOrCancel(iterator, cancellation)) {
        ensureStagingIsCurrent();
        await writeChunk(iterator.current);
      }
      ensureStagingIsCurrent();
      digestInput.close();
      final digest = digestSink.value?.toString();
      if (digest == null) {
        throw StateError('WebDAV root staging hash is empty.');
      }
      final finished = _map(
        await channel.invokeMethod<Object?>(
          'localStageFinish',
          <String, Object?>{
            'token': grant.token,
            'generation': grant.generation,
            'key': key,
            'expectedSha256': digest,
          },
        ),
      );
      ensureStagingIsCurrent();
      if (_text(finished['key']) != key ||
          _text(finished['sha256']) != digest) {
        throw StateError('WebDAV root staging hash verification failed.');
      }
      return _BodyReference.root(
        key: key,
        token: grant.token,
        generation: grant.generation,
        length: offset,
      );
    } catch (_) {
      await _cleanupRootBody(
        _BodyReference.root(
          key: key,
          token: grant.token,
          generation: grant.generation,
          length: offset,
        ),
      );
      rethrow;
    } finally {
      await _cancelIterator(iterator);
      unawaited(cancellation);
    }
  }

  Future<void> _cleanupRootBody(_BodyReference body) async {
    if (body.key == null || body.token == null || body.generation == null) {
      return;
    }
    try {
      await channel.invokeMethod<Object?>(
        'webdavCleanupBody',
        <String, Object?>{
          'token': body.token,
          'generation': body.generation,
          'key': body.key,
        },
      );
    } catch (_) {
      // Native cleanup is best effort; the staged file remains inside the
      // authorized .synctune-local directory for the next recovery pass.
    }
  }

  static Map<String, List<String>> _responseHeaders(Object? value) {
    final map = _map(value);
    return <String, List<String>>{
      for (final entry in map.entries)
        entry.key.toLowerCase(): <String>['${entry.value}'],
    };
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map) throw StateError('Windows HTTP response was not a map.');
    return <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }

  static Uint8List _bytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    throw StateError('Windows HTTP response chunk was not bytes.');
  }

  static String? _text(Object? value) =>
      value == null || '$value'.isEmpty ? null : '$value';

  static int? _int(Object? value) => value is int ? value : null;

  static Duration _openTimeout(RequestOptions options) =>
      options.connectTimeout ?? const Duration(seconds: 20);

  static Duration _nativeOpenTimeout(RequestOptions options) =>
      options.sendTimeout ??
      options.connectTimeout ??
      const Duration(seconds: 60);

  static Duration _readTimeout(RequestOptions options) =>
      options.receiveTimeout ?? const Duration(seconds: 30);

  static Future<bool> _moveNextOrCancel(
    StreamIterator<Uint8List> iterator,
    Future<void>? cancellation,
  ) {
    if (cancellation == null) return iterator.moveNext();
    return Future.any<bool>(<Future<bool>>[
      iterator.moveNext(),
      cancellation.then<bool>((_) => false),
    ]);
  }

  static Future<void> _cancelIterator(
    StreamIterator<Uint8List> iterator,
  ) async {
    try {
      await iterator.cancel().timeout(const Duration(milliseconds: 500));
    } catch (_) {
      // A misbehaving source must not prevent request cancellation or stage
      // cleanup from returning to Dio.
    }
  }
}

final class _BodyReference {
  const _BodyReference.path(this.path)
    : key = null,
      token = null,
      generation = null,
      length = null;

  const _BodyReference.root({
    required this.key,
    required this.token,
    required this.generation,
    required this.length,
  }) : path = null;

  final String? path;
  final String? key;
  final String? token;
  final String? generation;
  final int? length;
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest digest) {
    if (value != null) throw StateError('Digest was added twice.');
    value = digest;
  }

  @override
  void close() {
    if (value == null) throw StateError('Digest was not produced.');
  }
}
