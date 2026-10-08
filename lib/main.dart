import 'package:flutter/material.dart';

import 'app/localization/strings.dart';
import 'app/sync_tune_app.dart';
import 'platform/sync_platform_adapters.dart';
import 'sync/state_store.dart';
import 'sync/sync_controller.dart';
import 'sync/sync_engine.dart';
import 'sync/webdav_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final platform = SyncPlatformAdapters();
    final stateStore = SqliteStateStore(await platform.databasePath());
    await stateStore.open();
    final config = ValueNotifier<SyncAppConfig>(
      SyncAppConfig.fromStore(stateStore.loadSettings()),
    );
    final controller = SyncController(
      engine: SyncEngine(
        localStore: platform.createLocalStore(),
        webDav: WebDavClient(),
        stateStore: stateStore,
      ),
      credentials: platform,
      executionHost: platform,
    );
    platform.bind(controller);
    runApp(
      SyncTuneApp(
        config: config,
        stateStore: stateStore,
        platform: platform,
        controller: controller,
        musicLibrary: platform,
      ),
    );
  } catch (error) {
    runApp(_StartupError(error: error));
  }
}

final class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final requested = WidgetsBinding.instance.platformDispatcher.locale;
    final locale =
        SyncTuneStrings.supportedLocales.any(
          (item) => item.languageCode == requested.languageCode,
        )
        ? requested
        : const Locale('en');
    return MaterialApp(
      locale: locale,
      supportedLocales: SyncTuneStrings.supportedLocales,
      localizationsDelegates: <LocalizationsDelegate<dynamic>>[
        SyncTuneStrings.delegate,
      ],
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(
              '${SyncTuneStrings(locale).text('SyncTune could not initialize its local state.')}\n$error',
            ),
          ),
        ),
      ),
    );
  }
}
