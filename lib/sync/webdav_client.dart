import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'sync_model.dart';

final class WebDavClient {
  WebDavClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(minutes: 5),
              receiveTimeout: const Duration(minutes: 5),
              followRedirects: false,
              responseType: ResponseType.bytes,
            ),
          );

  final Dio _dio;

  Uri _endpoint(SyncSettings settings) {
    final uri = Uri.tryParse(settings.serverUrl.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const SyncFailure(
        'Enter a valid WebDAV URL without embedded credentials, query, or fragment.',
      );
    }
    return uri;
  }

  List<String> _rootSegments(SyncSettings settings) {
    final raw = settings.remoteRoot.trim();
    if (raw.isEmpty || raw == '/') return const <String>[];
    if (raw.startsWith('/') || raw.contains('\\') || raw.contains('\u0000')) {
      throw const SyncFailure('The WebDAV folder must be a relative path.');
    }
    final pieces = raw.split('/').where((part) => part.isNotEmpty).toList();
    for (final piece in pieces) {
      if (piece == '.' ||
          piece == '..' ||
          piece.contains('/') ||
          piece.contains('?') ||
          piece.contains('#')) {
        throw const SyncFailure(
          'The WebDAV folder contains an unsupported path segment.',
        );
      }
    }
    return pieces;
  }

  Uri _rootUri(SyncSettings settings) {
    final endpoint = _endpoint(settings);
    final uri = endpoint.replace(
      pathSegments: <String>[
        ...endpoint.pathSegments.where((s) => s.isNotEmpty),
        ..._rootSegments(settings),
      ],
      query: null,
      fragment: null,
    );
    return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
  }

  Uri _uri(SyncSettings settings, SyncPath path) {
    final root = _rootUri(settings);
    return root.replace(
      pathSegments: <String>[
        ...root.pathSegments.where((s) => s.isNotEmpty),
        ...path.value.split('/'),
      ],
      query: null,
      fragment: null,
    );
  }

  Map<String, String> _headers(
    SyncSettings settings, {
    Map<String, String> extra = const <String, String>{},
  }) {
    final values = <String, String>{
      ...extra,
      HttpHeaders.acceptEncodingHeader: 'identity',
    };
    if (settings.username.isNotEmpty) {
      values[HttpHeaders.authorizationHeader] =
          'Basic ${base64Encode(utf8.encode('${settings.username}:${_secret(settings)}'))}';
    }
    return values;
  }

  String _activeSecret = '';
  void setSecret(String value) => _activeSecret = value;
  void clearSecret() => _activeSecret = '';
  String _secret(SyncSettings _) => _activeSecret;

  Future<void> testConnection(
    SyncSettings settings, {
    required String secret,
    required CancellationToken token,
  }) async {
    setSecret(secret);
    try {
      final root = _rootUri(settings);
      if (!await _metadataDirectory(settings, root, token)) {
        throw const SyncFailure(
          'The WebDAV URL does not identify an existing folder.',
        );
      }
    } finally {
      clearSecret();
    }
  }

  Future<Response<T>> _request<T>(
    SyncSettings settings,
    String method,
    Uri uri,
    CancellationToken token, {
    Object? data,
    Map<String, String> headers = const <String, String>{},
    ResponseType responseType = ResponseType.bytes,
    int? contentLength,
    bool conditionalMutation = false,
  }) async {
    token.throwIfCancelled();
    final cancel = CancelToken();
    final removeCancellationListener = token.listen(
      () => cancel.cancel('Sync cancelled.'),
    );
    final allHeaders = _headers(settings, extra: headers);
    if (contentLength != null) {
      allHeaders[HttpHeaders.contentLengthHeader] = '$contentLength';
    }
    try {
      final response = await _dio.requestUri<T>(
        uri,
        data: data,
        cancelToken: cancel,
        options: Options(
          method: method,
          headers: allHeaders,
          responseType: responseType,
          followRedirects: false,
          receiveDataWhenStatusError: true,
          validateStatus: (_) => true,
        ),
      );
      token.throwIfCancelled();
      final code = response.statusCode ?? 0;
      if (code == 412) {
        throw SyncFailure(
          'The WebDAV file changed during synchronization (HTTP 412). Start a new scan.',
          statusCode: 412,
          conditionalWriteRejected: conditionalMutation,
        );
      }
      if (code == 401) {
        throw const SyncFailure(
          'The WebDAV server rejected the account (HTTP 401).',
          statusCode: 401,
        );
      }
      if (code == 403) {
        throw const SyncFailure(
          'The WebDAV account does not have permission (HTTP 403).',
          statusCode: 403,
        );
      }
      if (code == 507) {
        throw const SyncFailure(
          'The WebDAV server has insufficient storage (HTTP 507).',
          statusCode: 507,
        );
      }
      if (code >= 300 && code < 400) {
        throw SyncFailure(
          'WebDAV redirects are not followed; server returned HTTP $code.',
          statusCode: code,
        );
      }
      return response;
    } on DioException catch (error) {
      if (token.isCancelled || error.type == DioExceptionType.cancel) {
        throw const SyncCancelled();
      }
      final type =
          error.type == DioExceptionType.connectionTimeout ||
              error.type == DioExceptionType.receiveTimeout ||
              error.type == DioExceptionType.sendTimeout
          ? 'The WebDAV request timed out.'
          : 'The WebDAV request failed.';
      throw SyncFailure(
        '$type ${error.message ?? ''}'.trim(),
        statusCode: error.response?.statusCode,
      );
    } finally {
      removeCancellationListener();
    }
  }

  Future<SyncScanResult> scan(
    SyncSettings settings,
    Map<SyncPath, BaselineEntry> baseline,
    Directory cacheDirectory,
    CancellationToken token, {
    void Function(String path)? onFile,
    SyncByteProgress? onBytes,
    SyncFileProgress? onMusicFile,
  }) async {
    await cacheDirectory.create(recursive: true);
    final root = _rootUri(settings);
    final queue = <({Uri uri, String relative})>[(uri: root, relative: '')];
    final output = <SyncFile>[];
    final occupiedPaths = <SyncOccupiedPath>[];
    final seen = <String>{};
    while (queue.isNotEmpty) {
      token.throwIfCancelled();
      final current = queue.removeLast();
      final response = await _request<List<int>>(
        settings,
        'PROPFIND',
        current.uri,
        token,
        headers: const <String, String>{
          'Depth': '1',
          HttpHeaders.contentTypeHeader: 'application/xml; charset=utf-8',
        },
        data: utf8.encode(
          '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getetag/></d:prop></d:propfind>',
        ),
      );
      if (response.statusCode != 207) {
        _requireSuccess(response.statusCode, 'List WebDAV folder');
        throw const SyncFailure(
          'The WebDAV server did not return a multistatus directory listing.',
        );
      }
      final bytes = response.data ?? const <int>[];
      final document = XmlDocument.parse(utf8.decode(bytes));
      if (document.rootElement.name.local != 'multistatus' ||
          document.rootElement.name.namespaceUri != 'DAV:') {
        throw const SyncFailure(
          'The WebDAV server returned an invalid directory listing.',
        );
      }
      final currentSegments = current.relative.isEmpty
          ? const <String>[]
          : current.relative.split('/');
      var foundCurrent = false;
      for (final element in document.descendants.whereType<XmlElement>().where(
        (item) => item.name.local == 'response',
      )) {
        token.throwIfCancelled();
        final href = _childText(element, 'href');
        if (href == null || href.isEmpty) {
          throw const SyncFailure(
            'The WebDAV server returned a listing entry without a path.',
          );
        }
        final targetUri = current.uri.resolve(href);
        _assertSameOrigin(_endpoint(settings), targetUri);
        if (targetUri.userInfo.isNotEmpty ||
            targetUri.hasQuery ||
            targetUri.hasFragment) {
          throw SyncFailure(
            'The WebDAV server returned an invalid file URL: "$href".',
          );
        }
        final relativeSegments = _relativeSegments(root, targetUri);
        if (relativeSegments == null) {
          throw SyncFailure(
            'The WebDAV server returned a path outside the selected folder: "$href".',
          );
        }
        final samePrefix =
            relativeSegments.length >= currentSegments.length &&
            List.generate(
              currentSegments.length,
              (index) => relativeSegments[index] == currentSegments[index],
            ).every((same) => same);
        if (!samePrefix ||
            relativeSegments.length > currentSegments.length + 1) {
          throw SyncFailure(
            'The WebDAV server returned an entry outside the current folder: "$href".',
          );
        }
        if (relativeSegments.length == currentSegments.length) {
          final self = _parseResponse(element, pathForError: current.relative);
          if (!self.isCollection) {
            throw SyncFailure(
              'The WebDAV path is not a folder: "${current.relative}".',
            );
          }
          foundCurrent = true;
          continue;
        }
        final name = relativeSegments.last;
        if (name.toLowerCase() == '.synctune' ||
            name.toLowerCase() == '.synctune-local') {
          continue;
        }
        final rel = relativeSegments.join('/');
        if (!seen.add(rel)) {
          throw SyncFailure(
            'The WebDAV listing contains a duplicate path "$rel".',
          );
        }
        final entry = _parseResponse(element, pathForError: rel);
        final occupiedPath = SyncPath.parse(rel);
        occupiedPaths.add(
          SyncOccupiedPath(path: rel, isDirectory: entry.isCollection),
        );
        if (entry.isCollection) {
          final collectionUri = targetUri.path.endsWith('/')
              ? targetUri
              : targetUri.replace(path: '${targetUri.path}/');
          queue.add((uri: collectionUri, relative: rel));
          continue;
        }
        if (!musicExtensions.contains(name.split('.').last.toLowerCase())) {
          continue;
        }
        final path = occupiedPath;
        if (entry.length != null && entry.length! < 0) {
          throw SyncFailure(
            'The WebDAV server returned an invalid file length.',
            path: path,
          );
        }
        final etag = entry.etag;
        final saved = baseline[path];
        onFile?.call(path.value);
        await onMusicFile?.call(path);
        if (_isStrongEtag(etag) && saved?.remoteEtag == etag) {
          output.add(
            SyncFile(
              path: path,
              sha256: saved!.sha256,
              size: entry.length ?? saved.remoteSize,
              etag: etag,
            ),
          );
        } else {
          final hashed = await _hashRemote(
            settings,
            path,
            token,
            etag: etag,
            expectedLength: entry.length,
            onBytes: onBytes == null
                ? null
                : (bytes) async {
                    await onBytes(path, bytes);
                  },
          );
          output.add(
            SyncFile(
              path: path,
              sha256: hashed.sha256,
              size: hashed.length,
              etag: hashed.etag ?? etag,
            ),
          );
        }
      }
      if (!foundCurrent) {
        throw SyncFailure(
          'The WebDAV server did not confirm the current folder "${current.relative}".',
        );
      }
    }
    output.sort((a, b) => a.path.compareTo(b.path));
    validateWindowsPathSet(output.map((file) => file.path));
    return SyncScanResult(files: output, occupiedPaths: occupiedPaths);
  }

  static String? _childText(XmlElement parent, String localName) {
    for (final child in parent.children.whereType<XmlElement>()) {
      if (child.name.namespaceUri == 'DAV:' && child.name.local == localName) {
        return child.innerText.trim();
      }
    }
    return null;
  }

  static int? _statusCode(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^\s*HTTP/\d(?:\.\d)?\s+(\d{3})(?:\s|$)')
        .firstMatch(value);
    return match == null ? null : int.parse(match.group(1)!);
  }

  static _DavEntry _parseResponse(
    XmlElement response, {
    required String pathForError,
  }) {
    final responseStatus = _statusCode(_childText(response, 'status'));
    if (responseStatus != null &&
        (responseStatus < 200 || responseStatus >= 300)) {
      throw SyncFailure(
        'The WebDAV server could not list this path (HTTP $responseStatus).',
        path: pathForError.isEmpty ? null : SyncPath.parse(pathForError),
        statusCode: responseStatus,
      );
    }
    var hasResourceType = false;
    var isCollection = false;
    String? etag;
    int? length;
    final propstats = response.children.whereType<XmlElement>().where(
      (element) =>
          element.name.namespaceUri == 'DAV:' &&
          element.name.local == 'propstat',
    );
    for (final propstat in propstats) {
      final code = _statusCode(_childText(propstat, 'status'));
      XmlElement? prop;
      for (final child in propstat.children.whereType<XmlElement>()) {
        if (child.name.namespaceUri == 'DAV:' && child.name.local == 'prop') {
          prop = child;
          break;
        }
      }
      if (prop == null || code == null) {
        throw SyncFailure(
          'The WebDAV server returned invalid properties for "$pathForError".',
        );
      }
      for (final property in prop.children.whereType<XmlElement>().where(
        (element) => element.name.namespaceUri == 'DAV:',
      )) {
        if (code < 200 || code >= 300) {
          if (code == 404 &&
              (property.name.local == 'getetag' ||
                  property.name.local == 'getcontentlength')) {
            continue;
          }
          throw SyncFailure(
            'The WebDAV server could not read ${property.name.local} for "$pathForError" (HTTP $code).',
            path: pathForError.isEmpty ? null : SyncPath.parse(pathForError),
            statusCode: code,
          );
        }
        switch (property.name.local) {
          case 'resourcetype':
            hasResourceType = true;
            isCollection = property.children.whereType<XmlElement>().any(
              (child) =>
                  child.name.namespaceUri == 'DAV:' &&
                  child.name.local == 'collection',
            );
            break;
          case 'getetag':
            etag = property.innerText.trim();
            break;
          case 'getcontentlength':
            final raw = property.innerText.trim();
            if (raw.isNotEmpty) {
              length = int.tryParse(raw);
              if (length == null) {
                throw SyncFailure(
                  'The WebDAV server returned an invalid content length for "$pathForError".',
                );
              }
            }
            break;
        }
      }
    }
    if (!hasResourceType) {
      throw SyncFailure(
        'The WebDAV server did not confirm the resource type for "$pathForError".',
      );
    }
    if (length != null && length < 0) {
      throw SyncFailure(
        'The WebDAV server returned an invalid content length for "$pathForError".',
      );
    }
    return _DavEntry(isCollection: isCollection, etag: etag, length: length);
  }

  static List<String>? _relativeSegments(Uri root, Uri target) {
    final rootParts = root.pathSegments
        .where((part) => part.isNotEmpty)
        .toList();
    final targetParts = target.pathSegments
        .where((part) => part.isNotEmpty)
        .toList();
    if (targetParts.length < rootParts.length) return null;
    for (var index = 0; index < rootParts.length; index++) {
      if (targetParts[index] != rootParts[index]) return null;
    }
    final result = targetParts.skip(rootParts.length).toList();
    if (result.any(
      (part) =>
          part.contains('/') ||
          part.contains('\\') ||
          part == '.' ||
          part == '..',
    )) {
      return null;
    }
    return result;
  }

  static void _assertSameOrigin(Uri endpoint, Uri target) {
    if (endpoint.scheme != target.scheme ||
        endpoint.host.toLowerCase() != target.host.toLowerCase() ||
        endpoint.port != target.port) {
      throw const SyncFailure(
        'The WebDAV server returned a path on a different origin.',
      );
    }
  }

  Future<({File file, String sha256, int length, String? etag})>
  _downloadToFile(
    SyncSettings settings,
    SyncPath path,
    Directory directory,
    CancellationToken token, {
    String? etag,
    int? expectedLength,
    Future<void> Function(int bytes)? onBytes,
  }) async {
    final headers = <String, String>{};
    if (etag != null &&
        RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(etag)) {
      headers[HttpHeaders.ifMatchHeader] = etag;
    }
    final response = await _request<ResponseBody>(
      settings,
      'GET',
      _uri(settings, path),
      token,
      headers: headers,
      responseType: ResponseType.stream,
    );
    _requireSuccess(response.statusCode, 'Read WebDAV file');
    final returnedEtag = response.headers.value(HttpHeaders.etagHeader);
    if (etag != null &&
        RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(etag) &&
        returnedEtag != null &&
        returnedEtag != etag) {
      throw SyncFailure(
        'WebDAV content changed while it was being read.',
        path: path,
      );
    }
    final file = File(
      '${directory.path}${Platform.pathSeparator}remote-${_temporaryId()}.part',
    );
    final sink = file.openWrite();
    final digests = _DigestSink();
    final converter = sha256.startChunkedConversion(digests);
    var length = 0;
    try {
      final body = response.data;
      if (body == null) {
        throw SyncFailure(
          'The WebDAV server returned no file body.',
          path: path,
        );
      }
      await for (final chunk in body.stream) {
        token.throwIfCancelled();
        converter.add(chunk);
        sink.add(chunk);
        length += chunk.length;
        await onBytes?.call(chunk.length);
        await sink.flush();
      }
      converter.close();
      await sink.flush();
      await sink.close();
      if (expectedLength != null && expectedLength != length) {
        throw SyncFailure(
          'WebDAV content length changed while it was being read.',
          path: path,
        );
      }
      return (
        file: file,
        sha256: digests.value.toString(),
        length: length,
        etag: returnedEtag,
      );
    } catch (_) {
      await sink.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<_HashResultWithEtag> _hashRemote(
    SyncSettings settings,
    SyncPath path,
    CancellationToken token, {
    String? etag,
    int? expectedLength,
    Future<void> Function(int bytes)? onBytes,
  }) async {
    final headers = <String, String>{};
    if (_isStrongEtag(etag)) headers[HttpHeaders.ifMatchHeader] = etag!;
    final response = await _request<ResponseBody>(
      settings,
      'GET',
      _uri(settings, path),
      token,
      headers: headers,
      responseType: ResponseType.stream,
    );
    _requireSuccess(response.statusCode, 'Read WebDAV file');
    final returnedEtag = response.headers.value(HttpHeaders.etagHeader);
    if (_isStrongEtag(etag) && returnedEtag != null && returnedEtag != etag) {
      throw SyncFailure(
        'WebDAV content changed while it was being read.',
        path: path,
      );
    }
    final body = response.data;
    if (body == null) {
      throw SyncFailure('The WebDAV server returned no file body.', path: path);
    }
    final digests = _DigestSink();
    final converter = sha256.startChunkedConversion(digests);
    var length = 0;
    await for (final chunk in body.stream) {
      token.throwIfCancelled();
      converter.add(chunk);
      length += chunk.length;
      await onBytes?.call(chunk.length);
    }
    converter.close();
    if (expectedLength != null && expectedLength != length) {
      throw SyncFailure(
        'WebDAV content length changed while it was being read.',
        path: path,
      );
    }
    return _HashResultWithEtag(digests.value.toString(), length, returnedEtag);
  }

  Future<File> prepareSource(
    SyncSettings settings,
    SyncFile source,
    Directory cacheDirectory,
    CancellationToken token, {
    SyncByteProgress? onBytes,
  }) async {
    final cached = source.cachedFile;
    if (cached != null && await cached.exists()) return cached;
    final read = await _downloadToFile(
      settings,
      source.path,
      cacheDirectory,
      token,
      etag: source.etag,
      onBytes: onBytes == null
          ? null
          : (bytes) async {
              await onBytes(source.path, bytes);
            },
    );
    if (read.sha256 != source.sha256) {
      await read.file.delete();
      throw SyncFailure(
        'WebDAV content changed since scanning; start a new scan.',
        path: source.path,
      );
    }
    return read.file;
  }

  Future<SyncFile?> inspect(
    SyncSettings settings,
    SyncPath path,
    Map<SyncPath, BaselineEntry> baseline,
    Directory cacheDirectory,
    CancellationToken token,
  ) async {
    final metadata = await _metadata(settings, path, token);
    if (metadata == null) return null;
    final saved = baseline[path];
    if (_isStrongEtag(metadata.etag) && saved?.remoteEtag == metadata.etag) {
      return SyncFile(
        path: path,
        sha256: saved!.sha256,
        size: metadata.length ?? saved.remoteSize,
        etag: metadata.etag,
      );
    }
    final read = await _hashRemote(
      settings,
      path,
      token,
      etag: metadata.etag,
      expectedLength: metadata.length,
    );
    return SyncFile(
      path: path,
      sha256: read.sha256,
      size: read.length,
      etag: read.etag ?? metadata.etag,
    );
  }

  Future<({String? etag, int length})> put(
    SyncSettings settings,
    SyncPath path,
    Stream<List<int>> staged,
    int expectedLength,
    String? previousHash,
    String? previousEtag,
    String backupPath,
    CancellationToken token, {
    SyncByteProgress? onBytes,
  }) async {
    final metadata = await _metadata(settings, path, token);
    if ((previousHash == null) != (metadata == null)) {
      throw SyncFailure(
        'The WebDAV target changed after scanning; start a new scan.',
        path: path,
      );
    }
    String? conditionEtag;
    if (metadata != null && previousHash != null) {
      conditionEtag = metadata.etag;
      final backup = await _preserveRemote(
        settings,
        path,
        metadata,
        previousHash,
        previousEtag,
        backupPath,
        token,
      );
      if (!backup) {
        throw SyncFailure(
          'Could not preserve the previous WebDAV file.',
          path: path,
        );
      }
      if (!_isStrongEtag(metadata.etag)) {
        final checked = await _downloadToFile(
          settings,
          path,
          Directory(File(backupPath).parent.path),
          token,
          etag: metadata.etag,
          expectedLength: metadata.length,
        );
        try {
          if (checked.sha256 != previousHash) {
            throw SyncFailure(
              'The WebDAV target changed before upload; start a new scan.',
              path: path,
            );
          }
        } finally {
          if (await checked.file.exists()) await checked.file.delete();
        }
      }
    }
    final currentMetadata = metadata;
    if (currentMetadata != null &&
        currentMetadata.etag != null &&
        currentMetadata.etag!.isNotEmpty &&
        previousEtag != null &&
        currentMetadata.etag != previousEtag) {
      throw SyncFailure(
        'The WebDAV target changed after scanning; start a new scan.',
        path: path,
      );
    }
    final headers = <String, String>{};
    if (metadata == null) {
      headers[HttpHeaders.ifNoneMatchHeader] = '*';
    } else if (conditionEtag != null &&
        RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(conditionEtag)) {
      headers[HttpHeaders.ifMatchHeader] = conditionEtag;
    }
    final tracked = onBytes == null
        ? staged
        : staged.asyncMap((chunk) async {
            token.throwIfCancelled();
            await onBytes(path, chunk.length);
            return chunk;
          });
    final response = await _request<List<int>>(
      settings,
      'PUT',
      _uri(settings, path),
      token,
      data: tracked,
      headers: headers,
      contentLength: expectedLength,
      conditionalMutation: true,
    );
    _requireSuccess(response.statusCode, 'Upload WebDAV file');
    return (
      etag: response.headers.value(HttpHeaders.etagHeader),
      length: expectedLength,
    );
  }

  Future<void> delete(
    SyncSettings settings,
    SyncPath path,
    String expectedHash,
    String? expectedEtag,
    String backupPath,
    CancellationToken token,
  ) async {
    final metadata = await _metadata(settings, path, token);
    if (metadata == null) {
      throw SyncFailure(
        'The WebDAV delete target disappeared after scanning.',
        path: path,
      );
    }
    await _preserveRemote(
      settings,
      path,
      metadata,
      expectedHash,
      expectedEtag,
      backupPath,
      token,
    );
    final headers = <String, String>{};
    final etag = metadata.etag;
    if (!_isStrongEtag(etag)) {
      final checked = await _downloadToFile(
        settings,
        path,
        File(backupPath).parent,
        token,
        etag: etag,
        expectedLength: metadata.length,
      );
      try {
        if (checked.sha256 != expectedHash) {
          throw SyncFailure(
            'The WebDAV delete target changed before deletion; start a new scan.',
            path: path,
          );
        }
      } finally {
        if (await checked.file.exists()) await checked.file.delete();
      }
    }
    if (etag != null &&
        RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(etag)) {
      headers[HttpHeaders.ifMatchHeader] = etag;
    }
    final response = await _request<List<int>>(
      settings,
      'DELETE',
      _uri(settings, path),
      token,
      headers: headers,
      conditionalMutation: true,
    );
    _requireSuccess(response.statusCode, 'Delete WebDAV file');
    if (await _metadata(settings, path, token) != null) {
      throw SyncFailure(
        'The WebDAV server did not confirm deletion.',
        path: path,
      );
    }
  }

  Future<bool> _preserveRemote(
    SyncSettings settings,
    SyncPath path,
    _RemoteMetadata metadata,
    String expectedHash,
    String? expectedEtag,
    String backupPath,
    CancellationToken token,
  ) async {
    final backup = File(backupPath);
    await backup.parent.create(recursive: true);
    final storedExists = await backup.exists();
    if (storedExists &&
        (await _hashFile(backup, token)).sha256 != expectedHash) {
      throw SyncFailure(
        'A saved WebDAV recovery copy has unexpected content.',
        path: path,
      );
    }
    final strongNow = _isStrongEtag(metadata.etag);
    final strongBefore = _isStrongEtag(expectedEtag);
    if (strongNow && strongBefore && metadata.etag != expectedEtag) {
      throw SyncFailure(
        'The WebDAV target changed after scanning; start a new scan.',
        path: path,
      );
    }
    if (storedExists &&
        strongNow &&
        strongBefore &&
        metadata.etag == expectedEtag) {
      return true;
    }
    final copied = await _downloadToFile(
      settings,
      path,
      backup.parent,
      token,
      etag: metadata.etag,
      expectedLength: metadata.length,
    );
    if (copied.sha256 != expectedHash) {
      await copied.file.delete();
      throw SyncFailure(
        'The WebDAV target changed after scanning; start a new scan.',
        path: path,
      );
    }
    if (storedExists) {
      await copied.file.delete();
    } else {
      await copied.file.rename(backup.path);
    }
    return true;
  }

  Future<_RemoteMetadata?> _metadata(
    SyncSettings settings,
    SyncPath path,
    CancellationToken token,
  ) async {
    final response = await _request<List<int>>(
      settings,
      'PROPFIND',
      _uri(settings, path),
      token,
      headers: const <String, String>{
        'Depth': '0',
        HttpHeaders.contentTypeHeader: 'application/xml; charset=utf-8',
      },
      data: utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getetag/></d:prop></d:propfind>',
      ),
    );
    final code = response.statusCode ?? 0;
    if (code == HttpStatus.notFound) return null;
    if (code != 207) {
      _requireSuccess(code, 'Read WebDAV metadata');
      throw const SyncFailure(
        'The WebDAV server did not return metadata as a multistatus response.',
      );
    }
    final document = XmlDocument.parse(
      utf8.decode(response.data ?? const <int>[]),
    );
    if (document.rootElement.name.local != 'multistatus' ||
        document.rootElement.name.namespaceUri != 'DAV:') {
      throw const SyncFailure('The WebDAV server returned invalid metadata.');
    }
    final elements = document.descendants
        .whereType<XmlElement>()
        .where(
          (item) =>
              item.name.namespaceUri == 'DAV:' && item.name.local == 'response',
        )
        .toList();
    if (elements.length != 1) {
      throw const SyncFailure(
        'The WebDAV server returned ambiguous file metadata.',
      );
    }
    final element = elements.single;
    if (_statusCode(_childText(element, 'status')) == HttpStatus.notFound) {
      return null;
    }
    final href = _childText(element, 'href');
    if (href == null) {
      throw const SyncFailure(
        'The WebDAV server returned metadata without a path.',
      );
    }
    final requestUri = _uri(settings, path);
    final target = requestUri.resolve(href);
    _assertSameOrigin(_endpoint(settings), target);
    if (target.userInfo.isNotEmpty || target.hasQuery || target.hasFragment) {
      throw SyncFailure(
        'The WebDAV server returned an invalid metadata URL for "${path.value}".',
        path: path,
      );
    }
    if (target.pathSegments.where((part) => part.isNotEmpty).join('/') !=
        _uri(
          settings,
          path,
        ).pathSegments.where((part) => part.isNotEmpty).join('/')) {
      throw SyncFailure(
        'The WebDAV server returned metadata for a different path than "${path.value}".',
        path: path,
      );
    }
    final parsed = _parseResponse(element, pathForError: path.value);
    if (parsed.isCollection) {
      throw SyncFailure(
        'A folder occupies the expected music-file path.',
        path: path,
      );
    }
    return _RemoteMetadata(parsed.etag, parsed.length);
  }

  Future<void> ensureParents(
    SyncSettings settings,
    SyncPath path,
    CancellationToken token,
  ) async {
    final parents = <List<String>>[];
    final pieces = path.value.split('/');
    for (var index = 1; index < pieces.length; index++) {
      parents.add(pieces.take(index).toList());
    }
    for (final parent in parents) {
      token.throwIfCancelled();
      final uri = _rootUri(settings).replace(
        pathSegments: <String>[
          ..._rootUri(settings).pathSegments.where((s) => s.isNotEmpty),
          ...parent,
        ],
      );
      final response = await _request<List<int>>(settings, 'MKCOL', uri, token);
      final code = response.statusCode ?? 0;
      if (code == HttpStatus.methodNotAllowed || code == HttpStatus.conflict) {
        final exists = await _metadataDirectory(settings, uri, token);
        if (!exists) {
          throw SyncFailure(
            'Could not create a WebDAV parent folder for "${path.value}" (HTTP $code).',
            path: path,
            statusCode: code,
          );
        }
      } else {
        _requireSuccess(code, 'Create WebDAV folder');
      }
    }
  }

  Future<void> ensureRoot(
    SyncSettings settings,
    CancellationToken token,
  ) async {
    final endpoint = _endpoint(settings);
    final root = _rootUri(settings);
    final base = endpoint.pathSegments
        .where((part) => part.isNotEmpty)
        .toList();
    final remote = _rootSegments(settings);
    for (var index = 1; index <= remote.length; index++) {
      token.throwIfCancelled();
      final uri = endpoint.replace(
        pathSegments: <String>[...base, ...remote.take(index)],
        query: null,
        fragment: null,
      );
      final response = await _request<List<int>>(settings, 'MKCOL', uri, token);
      final code = response.statusCode ?? 0;
      if (code == HttpStatus.methodNotAllowed || code == HttpStatus.conflict) {
        if (!await _metadataDirectory(settings, uri, token)) {
          throw SyncFailure(
            'Could not create the selected WebDAV folder (HTTP $code).',
            statusCode: code,
          );
        }
      } else {
        _requireSuccess(code, 'Create selected WebDAV folder');
      }
    }
    if (remote.isEmpty && !await _metadataDirectory(settings, root, token)) {
      throw const SyncFailure(
        'The configured WebDAV endpoint is not a directory.',
      );
    }
  }

  Future<bool> _metadataDirectory(
    SyncSettings settings,
    Uri uri,
    CancellationToken token,
  ) async {
    final response = await _request<List<int>>(
      settings,
      'PROPFIND',
      uri,
      token,
      headers: const <String, String>{
        'Depth': '0',
        HttpHeaders.contentTypeHeader: 'application/xml; charset=utf-8',
      },
      data: utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
      ),
    );
    if (response.statusCode == HttpStatus.notFound) return false;
    if (response.statusCode != 207) {
      _requireSuccess(response.statusCode, 'Check WebDAV folder');
      throw const SyncFailure(
        'The WebDAV server did not return folder metadata as a multistatus response.',
      );
    }
    final document = XmlDocument.parse(
      utf8.decode(response.data ?? const <int>[]),
    );
    if (document.rootElement.name.local != 'multistatus' ||
        document.rootElement.name.namespaceUri != 'DAV:') {
      throw const SyncFailure(
        'The WebDAV server returned invalid folder metadata.',
      );
    }
    final elements = document.descendants
        .whereType<XmlElement>()
        .where(
          (item) =>
              item.name.namespaceUri == 'DAV:' && item.name.local == 'response',
        )
        .toList();
    if (elements.length != 1) {
      throw const SyncFailure(
        'The WebDAV server returned invalid folder metadata.',
      );
    }
    final element = elements.single;
    if (_statusCode(_childText(element, 'status')) == HttpStatus.notFound) {
      return false;
    }
    final href = _childText(element, 'href');
    if (href == null) {
      throw const SyncFailure(
        'The WebDAV server returned folder metadata without a path.',
      );
    }
    final target = uri.resolve(href);
    _assertSameOrigin(_endpoint(settings), target);
    if (target.pathSegments.where((part) => part.isNotEmpty).join('/') !=
        uri.pathSegments.where((part) => part.isNotEmpty).join('/')) {
      throw const SyncFailure(
        'The WebDAV server returned metadata for a different folder.',
      );
    }
    return _parseResponse(element, pathForError: '').isCollection;
  }

  Future<void> cleanupBackup(
    String exactPath,
    String operationId,
    String? expectedHash,
    CancellationToken token,
  ) async {
    if (expectedHash == null) {
      if (await File(exactPath).exists()) {
        throw const SyncFailure('An unexpected WebDAV recovery file was kept.');
      }
      return;
    }
    final expectedId = RegExp.escape(operationId);
    if (!RegExp('[/\\\\]remote[/\\\\]$expectedId\\.backup\$')
        .hasMatch(exactPath)) {
      throw const SyncFailure(
        'Refusing to clean a WebDAV recovery file not owned by this operation.',
      );
    }
    final file = File(exactPath);
    if (!await file.exists()) return;
    if ((await _hashFile(file, token)).sha256 != expectedHash) {
      throw const SyncFailure(
        'Unknown content remains in a WebDAV recovery file; it was kept.',
      );
    }
    await file.delete();
  }

  static void _requireSuccess(int? status, String action) {
    final code = status ?? 0;
    if (code >= 200 && code < 300) return;
    if (code == 412) {
      throw const SyncFailure(
        'The WebDAV file changed during synchronization (HTTP 412). Start a new scan.',
        statusCode: 412,
      );
    }
    throw SyncFailure('$action failed (HTTP $code).', statusCode: code);
  }

  static String _temporaryId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
}

final class _RemoteMetadata {
  const _RemoteMetadata(this.etag, this.length);
  final String? etag;
  final int? length;
}

final class _HashResultWithEtag {
  const _HashResultWithEtag(this.sha256, this.length, this.etag);
  final String sha256;
  final int length;
  final String? etag;
}

final class _DavEntry {
  const _DavEntry({
    required this.isCollection,
    required this.etag,
    required this.length,
  });
  final bool isCollection;
  final String? etag;
  final int? length;
}

bool _isStrongEtag(String? value) =>
    value != null && RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value);

final class _HashResult {
  const _HashResult(this.sha256, this.length);
  final String sha256;
  final int length;
}

Future<_HashResult> _hashFile(File file, CancellationToken token) async {
  final sink = _DigestSink();
  final converter = sha256.startChunkedConversion(sink);
  var length = 0;
  await for (final chunk in file.openRead()) {
    token.throwIfCancelled();
    converter.add(chunk);
    length += chunk.length;
  }
  converter.close();
  return _HashResult(sink.value.toString(), length);
}

final class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value =>
      _value ?? (throw StateError('Hash conversion produced no digest.'));
  @override
  void add(Digest value) => _value = value;
  @override
  void close() {}
}
