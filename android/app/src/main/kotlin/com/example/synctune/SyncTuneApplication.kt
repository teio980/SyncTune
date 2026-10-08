package com.example.synctune

import android.app.Application
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugins.GeneratedPluginRegistrant

class SyncTuneApplication : Application() {
    lateinit var engine: FlutterEngine
        private set

    override fun onCreate() {
        super.onCreate()
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(this)
        loader.ensureInitializationComplete(this, null)

        engine = FlutterEngine(this, null, false)
        GeneratedPluginRegistrant.registerWith(engine)
        engine.plugins.add(SyncPlatformPlugin(this))
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        engine.dartExecutor.executeDartEntrypoint(
            io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint.createDefault(),
        )
    }

    override fun onTerminate() {
        if (::engine.isInitialized) engine.destroy()
        super.onTerminate()
    }

    companion object {
        const val ENGINE_ID = "synctune-engine"
    }

    var platformChannel: io.flutter.plugin.common.MethodChannel? = null
}
