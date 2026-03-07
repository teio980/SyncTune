package com.example.synctune.sync

import android.content.Context
import android.content.SharedPreferences

class SyncManager(context: Context) {

    private val sharedPreferences: SharedPreferences = context.getSharedPreferences("SyncSettings", Context.MODE_PRIVATE)

    // General Sync Settings
    fun setSyncEnabled(enabled: Boolean) {
        sharedPreferences.edit().putBoolean("sync_enabled", enabled).apply()
    }

    fun isSyncEnabled(): Boolean = sharedPreferences.getBoolean("sync_enabled", false)

    fun setAutoSyncEnabled(enabled: Boolean) {
        sharedPreferences.edit().putBoolean("auto_sync_enabled", enabled).apply()
    }

    fun isAutoSyncEnabled(): Boolean = sharedPreferences.getBoolean("auto_sync_enabled", false)

    fun setLastSyncTime(time: Long) {
        sharedPreferences.edit().putLong("last_sync_time", time).apply()
    }

    fun getLastSyncTime(): Long = sharedPreferences.getLong("last_sync_time", 0L)

    // WebDAV Configuration
    fun saveWebDAVConfig(url: String, user: String, pass: String) {
        sharedPreferences.edit()
            .putString("webdav_url", url)
            .putString("webdav_user", user)
            .putString("webdav_pass", pass)
            .putBoolean("webdav_configured", true)
            .apply()
    }

    fun getWebDAVUrl(): String? = sharedPreferences.getString("webdav_url", null)
    fun getWebDAVUser(): String? = sharedPreferences.getString("webdav_user", null)
    fun getWebDAVPass(): String? = sharedPreferences.getString("webdav_pass", null)
    fun isWebDAVConfigured(): Boolean = sharedPreferences.getBoolean("webdav_configured", false)

    fun disconnectWebDAV() {
        sharedPreferences.edit()
            .remove("webdav_url")
            .remove("webdav_user")
            .remove("webdav_pass")
            .putBoolean("webdav_configured", false)
            .apply()
    }
}
