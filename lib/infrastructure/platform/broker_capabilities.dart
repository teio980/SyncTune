import 'broker_local_object_store.dart';

/// Provider capabilities exposed by the native broker. Values are strings on
/// purpose: a provider can expose a weaker, explicitly named primitive than a
/// Dart boolean whose meaning might accidentally be widened later.
final class BrokerCapabilities {
  const BrokerCapabilities({
    required this.platform,
    required this.credentials,
    required this.staging,
    required this.atomicCreate,
    required this.conditionalReplace,
    required this.conditionalDelete,
    required this.temporaryPermission,
  });

  final String platform;
  final String credentials;
  final String staging;
  final String atomicCreate;
  final String conditionalReplace;
  final String conditionalDelete;
  final String temporaryPermission;

  bool get canCreateOnly => atomicCreate == 'fail_if_exists_verified';

  bool get canConditionalReplace =>
      conditionalReplace == 'provider_compare_and_swap';

  bool get canConditionalDelete =>
      conditionalDelete == 'provider_compare_and_delete';

  /// A provider operation that verifies the expected bytes, keeps a durable
  /// backup, then publishes and verifies the replacement. This is deliberately
  /// separate from an atomic compare-and-swap claim.
  bool get canVerifiedBackupReplace =>
      conditionalReplace == 'verified_backup_replace';

  /// A provider operation that verifies the expected bytes, keeps a durable
  /// backup, then removes the file and verifies that it is absent.
  bool get canVerifiedBackupDelete =>
      conditionalDelete == 'verified_backup_delete';

  bool get canVerifiedCreate => atomicCreate == 'verified_create_recovery';

  factory BrokerCapabilities.fromResponse(Object? value) {
    if (value is! Map) {
      throw const BrokerError(
        'protocol',
        'Broker capability response is not a map.',
      );
    }
    final response = value.cast<Object?, Object?>();
    if (response['status'] != 'ok') {
      throw BrokerError(
        response['code']?.toString() ?? 'broker_denied',
        response['error']?.toString() ?? 'Broker capability query failed.',
      );
    }
    String field(String name) {
      final raw = response[name];
      if (raw is! String || raw.isEmpty) {
        throw BrokerError(
          'protocol',
          'Broker capability field "$name" is missing.',
        );
      }
      return raw;
    }

    return BrokerCapabilities(
      platform: field('platform'),
      credentials: field('credentials'),
      staging: field('staging'),
      atomicCreate: field('atomicCreate'),
      conditionalReplace: field('conditionalReplace'),
      conditionalDelete: field('conditionalDelete'),
      temporaryPermission: field('temporaryPermission'),
    );
  }
}

final class MethodChannelBrokerCapabilities {
  const MethodChannelBrokerCapabilities({required this.channel});

  final BrokerMethodChannel channel;

  Future<BrokerCapabilities> read() async {
    try {
      return BrokerCapabilities.fromResponse(
        await channel.invokeMethod<Object?>('brokerCapabilities'),
      );
    } on BrokerError {
      rethrow;
    } on Exception catch (error) {
      throw BrokerError('unavailable', error.toString());
    }
  }
}
