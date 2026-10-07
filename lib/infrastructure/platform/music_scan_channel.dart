import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/music/music_scan_port.dart';
import '../../app/sync/sync_status_view_model.dart';

/// Compatibility adapter for the existing probe channel. Production startup
/// may override the app port with the broker-backed scanner below or another
/// platform implementation.
const musicScanChannel = MethodChannel('synctune/probe');

final musicScannerPortProvider = Provider<MusicScannerPort>(
  (ref) => const MethodChannelMusicScanner(),
);

final class MethodChannelMusicScanner implements MusicScannerPort {
  const MethodChannelMusicScanner({this.channel = musicScanChannel});

  final MethodChannel channel;

  @override
  Future<Map<Object?, Object?>> scan(RootGrant grant) async {
    return await channel.invokeMethod<Map<Object?, Object?>>(
          'scanMusic',
          <String, Object?>{
            'token': grant.token,
            'generation': grant.generation,
          },
        ) ??
        <Object?, Object?>{};
  }
}
