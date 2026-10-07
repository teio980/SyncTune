import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:dio/dio.dart';

import 'app/app.dart';
import 'infrastructure/composition/synctune_composition.dart';
import 'infrastructure/network/windows_winrt_http_adapter.dart';
import 'infrastructure/platform/broker_local_object_store.dart';

const _probeChannel = MethodChannel('synctune/probe');
Map<String, Object?> _jsonMap(Map<Object?, Object?> value) {
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is String) result[entry.key as String] = entry.value;
  }
  return result;
}

Future<Map<Object?, Object?>> _processInfo() async {
  return await _probeChannel.invokeMethod<Map<Object?, Object?>>(
        'processInfo',
      ) ??
      <Object?, Object?>{};
}

Future<File?> _evidenceFile() async {
  final dbPath = await _probeChannel.invokeMethod<String>(
    'privateDatabasePath',
  );
  if (dbPath == null || dbPath.isEmpty) return null;
  final process = await _processInfo();
  final pid = process['pid'] ?? 'unknown';
  return File(
    '${File(dbPath).parent.path}${Platform.pathSeparator}'
    'synctune-probe-results-$pid.json',
  );
}

Future<void> _evidenceWriteQueue = Future<void>.value();
bool _evidenceInitialized = false;
Future<String>? _startupProbeInFlight;

Future<String> _runStartupProbeSingleFlight() {
  final existing = _startupProbeInFlight;
  if (existing != null) return existing;
  late final Future<String> operation;
  operation = _runStartupProbe().whenComplete(() {
    if (identical(_startupProbeInFlight, operation)) {
      _startupProbeInFlight = null;
    }
  });
  _startupProbeInFlight = operation;
  return operation;
}

Future<void> _saveEvidence(
  String key,
  Object? value, {
  bool reset = false,
}) async {
  final operation = _evidenceWriteQueue.then((_) async {
    try {
      final file = await _evidenceFile();
      if (file == null) return;
      var evidence = <String, dynamic>{};
      // `reset` only initializes this PID's evidence.  A picker result may
      // arrive first, and must never be erased by the later startup write.
      if (!reset || _evidenceInitialized) {
        if (await file.exists()) {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) evidence = Map<String, dynamic>.from(decoded);
        }
      }
      evidence['schema'] = 1;
      evidence['updatedAtUtc'] = DateTime.now().toUtc().toIso8601String();
      evidence[key] = value;
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(evidence), flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
      _evidenceInitialized = true;
    } catch (error) {
      debugPrint('Probe evidence write failed: $error');
    }
  });
  _evidenceWriteQueue = operation.then<void>((_) {}, onError: (_) {});
  await operation;
}

Future<String> _runStartupProbe() async {
  final messages = <String>[];
  final evidence = <String, Object?>{};
  try {
    evidence['process'] = _jsonMap(await _processInfo());
  } catch (error) {
    evidence['processError'] = '$error';
  }

  try {
    final raw = await _probeChannel.invokeMethod<Object?>('brokerCapabilities');
    if (raw is! Map) {
      throw StateError('Broker capability response was not a map');
    }
    final capabilities = _jsonMap(raw.cast<Object?, Object?>());
    evidence['brokerCapabilities'] = capabilities;
    messages.add('Broker capabilities: ${capabilities['status'] ?? 'failed'}');
  } on PlatformException catch (error) {
    evidence['brokerCapabilities'] = <String, Object?>{
      'status': 'failed',
      'error': error.message ?? error.code,
    };
    messages.add('Broker capabilities: failed (${error.message})');
  } on MissingPluginException catch (error) {
    evidence['brokerCapabilities'] = <String, Object?>{
      'status': 'not-run',
      'reason': '$error',
    };
    messages.add('Broker capabilities: unavailable on this platform');
  } catch (error) {
    evidence['brokerCapabilities'] = <String, Object?>{
      'status': 'failed',
      'error': '$error',
    };
    messages.add('Broker capabilities: failed ($error)');
  }
  try {
    final dbPath = await _probeChannel.invokeMethod<String>(
      'privateDatabasePath',
    );
    if (dbPath == null || dbPath.isEmpty) {
      throw StateError('Windows private LocalFolder path was empty');
    }
    var restartCheck = false;
    Object? persisted;
    final db = sqlite3.open(dbPath);
    try {
      db.execute('CREATE TABLE IF NOT EXISTS probe (value TEXT NOT NULL)');
      final previous = db.select('SELECT value FROM probe LIMIT 1');
      restartCheck =
          previous.isNotEmpty && previous.first['value'] == 'sqlite-ok';
      db.execute('DELETE FROM probe');
      db.execute("INSERT INTO probe (value) VALUES ('sqlite-ok')");
    } finally {
      db.close();
    }
    final reopened = sqlite3.open(dbPath);
    try {
      persisted = reopened.select('SELECT value FROM probe').first['value'];
    } finally {
      reopened.close();
    }
    evidence['sqlite'] = <String, Object?>{
      'status': 'passed',
      'restartCheck': restartCheck,
      'path': dbPath,
    };
    messages.add(
      'SQLite private file: $persisted; restart: '
      '${restartCheck ? 'ok' : 'pending'}',
    );
  } catch (error) {
    evidence['sqlite'] = <String, Object?>{
      'status': 'failed',
      'error': '$error',
    };
    messages.add('SQLite private file: failed ($error)');
  }
  try {
    if (Platform.isWindows) {
      final client =
          Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
                followRedirects: false,
                maxRedirects: 0,
                responseType: ResponseType.bytes,
              ),
            )
            ..httpClientAdapter = WindowsWinRtHttpAdapter(
              channel: const FlutterBrokerMethodChannel(_probeChannel),
            );
      try {
        final response = await client
            .get<Object?>('https://example.com')
            .timeout(const Duration(seconds: 20));
        final status = response.statusCode;
        messages.add(
          status == null ? 'Network: failed' : 'Network: HTTP $status',
        );
        final network = <String, Object?>{
          'status': status != null && status >= 200 && status < 300
              ? 'passed'
              : 'failed',
          'transport': 'dio_winrt_http',
        };
        if (status != null) network['httpStatus'] = status;
        evidence['https'] = network;
      } finally {
        client.close(force: true);
      }
    } else {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(Uri.parse('https://example.com'));
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        final passed = response.statusCode >= 200 && response.statusCode < 300;
        messages.add('Network: HTTP ${response.statusCode}');
        evidence['https'] = <String, Object?>{
          'status': passed ? 'passed' : 'failed',
          'httpStatus': response.statusCode,
          'transport': 'dart_io_http_client',
        };
        await response.drain<void>().timeout(const Duration(seconds: 5));
      } finally {
        client.close(force: true);
      }
    }
  } catch (error) {
    evidence['https'] = <String, Object?>{
      'status': 'failed',
      'transport': Platform.isWindows
          ? 'dio_winrt_http'
          : 'dart_io_http_client',
      'error': '$error',
    };
    messages.add('Network: failed ($error)');
  }
  try {
    final credential = await _probeChannel.invokeMethod<Map<Object?, Object?>>(
      'credentialRoundTrip',
    );
    messages.add('AppContainer: ${credential?['appContainer']}');
    messages.add('Credential Locker: ${credential?['status'] ?? 'failed'}');
    messages.add(
      'Credential restart check: ${credential?['restartCheck'] ?? 'failed'}',
    );
    evidence['credential'] = _jsonMap(credential ?? <Object?, Object?>{});
  } on PlatformException catch (error) {
    evidence['credential'] = <String, Object?>{
      'status': 'failed',
      'error': error.message,
    };
    messages.add('Native capability: failed (${error.message})');
  } on MissingPluginException catch (error) {
    evidence['credential'] = <String, Object?>{
      'status': 'not-run',
      'reason': '$error',
    };
    messages.add('Credential Locker: unavailable on this platform');
  }
  try {
    final restored = await _probeChannel
        .invokeMethod<Map<Object?, Object?>>('restoreFolder')
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => <Object?, Object?>{
            'status': 'not-run',
            'reason': 'bounded timeout',
          },
        );
    final folderStatus = restored?['status'] ?? 'none';
    final folderPhase = restored?['phase'];
    final folderFailure = folderStatus == 'failed' && folderPhase is String
        ? ' ($folderPhase)'
        : '';
    messages.add('Folder restart recovery: $folderStatus$folderFailure');
    if (restored?['fileIo'] != null) {
      messages.add('Folder restart file I/O: ${restored?['fileIo']}');
    }
    evidence['folderRestore'] = _jsonMap(restored ?? <Object?, Object?>{});
  } on PlatformException catch (error) {
    evidence['folderRestore'] = <String, Object?>{
      'status': 'failed',
      'error': error.message,
    };
    messages.add('Folder restart recovery: failed (${error.message})');
  } on MissingPluginException catch (error) {
    evidence['folderRestore'] = <String, Object?>{
      'status': 'not-run',
      'reason': '$error',
    };
    messages.add('Folder restart recovery: unavailable on this platform');
  }

  await _saveEvidence('startup', evidence, reset: true);
  return messages.join('\n');
}

Future<String> _pickFolder() async {
  try {
    final result = await _probeChannel.invokeMethod<Map<Object?, Object?>>(
      'pickFolder',
    );
    if (result == null) return 'Folder authorization: cancelled';
    await _saveEvidence('folderPick', _jsonMap(result));
    return 'Folder authorization: ${result['status']}\n'
        'Token: ${result['token']}\n'
        'Reopen: ${result['reopen']}\n'
        'File I/O: ${result['fileIo']}\n'
        'Marker: ${result['marker']}\n'
        'Marker content: ${result['markerContent']}\n'
        'Path: ${result['path']}';
  } on PlatformException catch (error) {
    await _saveEvidence('folderPick', <String, Object?>{
      'status': 'failed',
      'error': error.message ?? error.code,
    });
    return 'Folder authorization: failed (${error.message})';
  } on MissingPluginException catch (error) {
    await _saveEvidence('folderPick', <String, Object?>{
      'status': 'not-run',
      'reason': '$error',
    });
    return 'Folder authorization: unavailable on this platform';
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = FlutterBrokerMethodChannel();
  final composition = await SyncTuneComposition.production(channel: channel);
  runApp(
    composition.provide(
      SyncTuneShell(
        onPickRoot: composition.pickRoot,
        onRestoreRoot: composition.restoreRoot,
        onRevokeRoot: composition.revokeRoot,
        diagnosticsBuilder: (_) => const ProbeApp(),
        initializationMessage: composition.initializationError,
      ),
    ),
  );
  // Keep the evidence current for the foreground scheduler.  The diagnostics
  // page can still be opened later to create the first marker for a root.
  unawaited(() async {
    try {
      await _runStartupProbeSingleFlight();
      // The scheduler may have checked before evidence became available. A
      // completed probe triggers one coalesced foreground check/run now.
      await composition.runtime.requestManual();
    } catch (_) {
      // The runtime publishes a blocked/failed state for the next check.
    }
  }());
}

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});

  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  String _startup = 'Running startup probes…';
  String _folder = 'No folder selected';
  bool _folderBusy = false;
  bool _startupBusy = true;

  @override
  void initState() {
    super.initState();
    _runStartupProbeSingleFlight().then((value) {
      if (mounted) {
        setState(() {
          _startup = value;
          _startupBusy = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: Localizations.maybeLocaleOf(context) ?? const Locale('en'),
      supportedLocales: SyncTuneStrings.supportedLocales,
      localizationsDelegates: const [
        SyncTuneStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      title: 'SyncTune AppContainer Probe',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF4F46E5)),
      home: Scaffold(
        appBar: AppBar(
          title: const LocalizedText('SyncTune AppContainer Probe'),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LocalizedText(
                'Flutter packaged classic AppContainer capability check',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              SelectableText(SyncTuneStrings.of(context).text(_startup)),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _folderBusy || _startupBusy
                    ? null
                    : () async {
                        setState(() => _folderBusy = true);
                        setState(
                          () => _folder = 'Opening Windows FolderPicker…',
                        );
                        try {
                          final result = await _pickFolder();
                          if (mounted) setState(() => _folder = result);
                        } finally {
                          if (mounted) setState(() => _folderBusy = false);
                        }
                      },
                icon: const Icon(Icons.folder_open),
                label: const LocalizedText('Choose authorized folder'),
              ),
              const SizedBox(height: 12),
              SelectableText(SyncTuneStrings.of(context).text(_folder)),
            ],
          ),
        ),
      ),
    );
  }
}
