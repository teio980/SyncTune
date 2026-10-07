import 'package:flutter/services.dart';

import 'broker_local_object_store.dart';

/// The credential port used by services that need a platform protected secret.
///
/// Implementations never persist the secret in Dart files, the database, or
/// diagnostic evidence. The production implementation sends it only to the
/// native broker, which stores it in Android Keystore or Windows PasswordVault.
abstract interface class BrokerCredentialStore {
  Future<void> save({
    required String service,
    required String account,
    required String secret,
  });

  Future<String?> read({required String service, required String account});

  Future<void> delete({required String service, required String account});
}

final class CredentialBrokerError implements Exception {
  const CredentialBrokerError(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'CredentialBrokerError($code): $message';
}

String normalizeCredentialKeyPart(String value) {
  final trimmed = value.trim();
  final normalized = String.fromCharCodes(
    trimmed.codeUnits.map(
      (unit) => unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit,
    ),
  );
  if (normalized.isEmpty || normalized.length > 128) {
    throw const CredentialBrokerError(
      'invalid_key',
      'Credential service and account keys must be non-empty and bounded.',
    );
  }
  for (final unit in normalized.codeUnits) {
    if (unit <= 31 || unit == 127 || unit == 47 || unit == 92 || unit == 58) {
      throw const CredentialBrokerError(
        'invalid_key',
        'Credential service and account keys contain an invalid character.',
      );
    }
  }
  return normalized;
}

/// Production channel adapter for [BrokerCredentialStore].
final class MethodChannelBrokerCredentialStore
    implements BrokerCredentialStore {
  const MethodChannelBrokerCredentialStore({required this.channel});

  final BrokerMethodChannel channel;

  Map<Object?, Object?> _response(Object? value, String method) {
    if (value is! Map) {
      throw CredentialBrokerError(
        'protocol',
        '$method returned a non-map response.',
      );
    }
    final response = value.cast<Object?, Object?>();
    if (response['status'] != 'ok') {
      throw CredentialBrokerError(
        response['code']?.toString() ?? 'credential_denied',
        response['error']?.toString() ?? '$method was not accepted.',
      );
    }
    return response;
  }

  Future<Map<Object?, Object?>> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      return _response(
        await channel.invokeMethod<Object?>(method, arguments),
        method,
      );
    } on PlatformException catch (error) {
      // Native adapters deliberately use generic messages. Never include the
      // secret in a Dart error or evidence object.
      throw CredentialBrokerError(
        error.code,
        error.message ?? 'Platform credential broker call failed.',
        error.details,
      );
    } on MissingPluginException catch (error) {
      throw CredentialBrokerError(
        'unavailable',
        error.message ?? 'Platform credential broker is unavailable.',
      );
    }
  }

  @override
  Future<void> save({
    required String service,
    required String account,
    required String secret,
  }) async {
    final response = await _invoke('credentialSave', <String, Object?>{
      'service': normalizeCredentialKeyPart(service),
      'account': normalizeCredentialKeyPart(account),
      'secret': secret,
    });
    if (response['stored'] != true) {
      throw const CredentialBrokerError(
        'protocol',
        'Credential broker did not confirm storage.',
      );
    }
  }

  @override
  Future<String?> read({
    required String service,
    required String account,
  }) async {
    final response = await _invoke('credentialRead', <String, Object?>{
      'service': normalizeCredentialKeyPart(service),
      'account': normalizeCredentialKeyPart(account),
    });
    final found = response['found'];
    if (found == false) return null;
    if (found != true || response['secret'] is! String) {
      throw const CredentialBrokerError(
        'protocol',
        'Credential broker returned an invalid read response.',
      );
    }
    return response['secret'] as String;
  }

  @override
  Future<void> delete({
    required String service,
    required String account,
  }) async {
    final response = await _invoke('credentialDelete', <String, Object?>{
      'service': normalizeCredentialKeyPart(service),
      'account': normalizeCredentialKeyPart(account),
    });
    if (response['deleted'] != true) {
      throw const CredentialBrokerError(
        'protocol',
        'Credential broker did not confirm deletion.',
      );
    }
  }
}
