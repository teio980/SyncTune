import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../../app/settings/settings_view_model.dart';
import '../platform/broker_local_object_store.dart';
import 'windows_winrt_http_adapter.dart';

/// Checks the form's connection independently of folder grants and sync gates.
/// A depth-zero PROPFIND reads only the configured collection's properties.
final class WebDavConnectionChecker implements WebDavConnectionCheckPort {
  const WebDavConnectionChecker({
    this.savedSettings,
    this.dioFactory,
    this.transportChannel,
  });

  final WebDavSettingsLoader? savedSettings;
  final Dio Function(BaseOptions options)? dioFactory;
  final BrokerMethodChannel? transportChannel;

  @override
  Future<void> check(WebDavSettings settings) async {
    final endpoint = canonicalWebDavEndpoint(settings.endpoint);
    if (endpoint == null) {
      throw const WebDavConnectionCheckException(
        'Enter a valid HTTPS WebDAV URL',
      );
    }
    var password = settings.password;
    if (password.isEmpty &&
        !settings.clearPassword &&
        settings.username.isNotEmpty &&
        savedSettings != null) {
      final saved = await savedSettings!.load().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw const WebDavConnectionCheckException(
          'Could not load the saved password. Enter it again and retry.',
        ),
      );
      if (canonicalWebDavEndpoint(saved.endpoint) == endpoint &&
          saved.username == settings.username) {
        password = saved.password;
      }
    }
    final options = BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        if (settings.username.isNotEmpty)
          'Authorization':
              'Basic ${base64Encode(utf8.encode('${settings.username}:$password'))}',
      },
    );
    final dio = dioFactory?.call(options) ?? Dio(options);
    if (Platform.isWindows && transportChannel != null) {
      dio.httpClientAdapter = WindowsWinRtHttpAdapter(
        channel: transportChannel!,
      );
    }
    try {
      final response = await dio
          .requestUri<String>(
            Uri.parse(endpoint),
            data:
                '<?xml version="1.0" encoding="utf-8"?>'
                '<d:propfind xmlns:d="DAV:"><d:prop>'
                '<d:resourcetype/></d:prop></d:propfind>',
            options: Options(
              method: 'PROPFIND',
              responseType: ResponseType.plain,
              headers: const {
                'Depth': '0',
                'Content-Type': 'application/xml; charset=utf-8',
              },
              followRedirects: false,
              maxRedirects: 0,
              validateStatus: (_) => true,
            ),
          )
          .timeout(const Duration(seconds: 15));
      final status = response.statusCode;
      final failure = switch (status) {
        401 => 'Authentication failed. Check your username and password.',
        403 => 'Access denied. Check your account permissions for this folder.',
        404 => 'The WebDAV folder was not found. Check the URL.',
        405 || 501 => 'This server does not support WebDAV connection checks.',
        301 || 302 || 303 || 307 || 308 => 'The server redirected the request. Enter the final HTTPS WebDAV URL.',
        207 => null,
        _ =>
          'The WebDAV server returned an unexpected response. Try again later.',
      };
      if (failure != null) throw WebDavConnectionCheckException(failure);
      if (!_isAccessibleCollection(response.data ?? '', endpoint)) {
        throw const WebDavConnectionCheckException(
          'The URL did not return an accessible WebDAV folder. Check the URL and permissions.',
        );
      }
    } on TimeoutException {
      throw const WebDavConnectionCheckException(
        'The connection timed out. Check the server and try again.',
      );
    } on DioException catch (error) {
      throw WebDavConnectionCheckException(switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          'The connection timed out. Check the server and try again.',
        DioExceptionType.badCertificate =>
          'The server certificate could not be verified.',
        _ => 'Could not reach the WebDAV server. Check the URL and network.',
      });
    } finally {
      dio.close(force: true);
    }
  }

  bool _isAccessibleCollection(String body, String endpoint) {
    try {
      final root = XmlDocument.parse(body).rootElement;
      if (root.name.local != 'multistatus' ||
          root.name.namespaceUri != 'DAV:') {
        return false;
      }
      for (final response in root.findElements(
        'response',
        namespaceUri: 'DAV:',
      )) {
        final href = response
            .getElement('href', namespaceUri: 'DAV:')
            ?.innerText;
        if (href == null ||
            canonicalWebDavEndpoint(
                  Uri.parse(endpoint).resolve(href.trim()).toString(),
                ) !=
                endpoint) {
          continue;
        }
        for (final propstat in response.findElements(
          'propstat',
          namespaceUri: 'DAV:',
        )) {
          final status = propstat
              .getElement('status', namespaceUri: 'DAV:')
              ?.innerText;
          if (status == null ||
              !RegExp(r'^HTTP/\d(?:\.\d)?\s+2\d\d\b').hasMatch(status.trim())) {
            continue;
          }
          final type = propstat
              .getElement('prop', namespaceUri: 'DAV:')
              ?.getElement('resourcetype', namespaceUri: 'DAV:');
          if (type?.getElement('collection', namespaceUri: 'DAV:') != null) {
            return true;
          }
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}
