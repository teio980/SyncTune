package com.example.synctune.sync

import android.content.Context
import android.content.SharedPreferences
import androidx.work.*
import java.util.concurrent.TimeUnit

class SyncManager(private val context: Context) {

    private val sharedPreferences: SharedPreferences = context.getSharedPreferences("SyncSettings", Context.MODE_PRIVATE)

    // General Sync Settings
    fun setSyncEnabled(enabled: Boolean) {
        sharedPreferences.edit().putBoolean("sync_enabled", enabled).apply()
        if (enabled && isAutoSyncEnabled()) {
            schedulePeriodicSync()
        } else {
            cancelPeriodicSync()
        }
    }

    fun isSyncEnabled(): Boolean = sharedPreferences.getBoolean("sync_enabled", false)

    fun setAutoSyncEnabled(enabled: Boolean) {
        sharedPreferences.edit().putBoolean("auto_sync_enabled", enabled).apply()
        if (enabled && isSyncEnabled()) {
            schedulePeriodicSync()
        } else {
            cancelPeriodicSync()
        }
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
        cancelPeriodicSync()
    }

    fun startImmediateSync(syncType: String = "TWO_WAY") {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val syncRequest = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(constraints)
            .setInputData(workDataOf("sync_type" to syncType))
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()

        WorkManager.getInstance(context).enqueueUniqueWork(
            "immediate_sync",
            ExistingWorkPolicy.REPLACE,
            syncRequest
        )
    }

    private fun schedulePeriodicSync() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.UNMETERED) // Default to WiFi for background sync
            .setRequiresBatteryNotLow(true)
            .build()

        val periodicSyncRequest = PeriodicWorkRequestBuilder<SyncWorker>(1, TimeUnit.HOURS)
            .setConstraints(constraints)
            .setInputData(workDataOf("sync_type" to "TWO_WAY"))
            .build()

        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            "periodic_sync",
            ExistingPeriodicWorkPolicy.KEEP,
            periodicSyncRequest
        )
    }

    private fun cancelPeriodicSync() {
        WorkManager.getInstance(context).cancelUniqueWork("periodic_sync")
    }
}
