package com.example.synctune.sync

import android.content.Context
import android.content.SharedPreferences
import androidx.work.*
import java.util.concurrent.TimeUnit

class SyncManager(private val context: Context) {

    companion object {
        const val UNIQUE_SYNC_WORK_NAME = "music_sync"
        const val SYNC_TAG_MANUAL = "manual_sync"
        const val SYNC_TYPE_TWO_WAY = "TWO_WAY"
    }

    // Use "SyncTunePrefs" for consistency across the app
    private val sharedPreferences: SharedPreferences = context.getSharedPreferences("SyncTunePrefs", Context.MODE_PRIVATE)

    fun setSyncEnabled(enabled: Boolean) {
        sharedPreferences.edit().putBoolean("sync_enabled", enabled).apply()
        if (enabled && isAutoSyncEnabled()) {
            schedulePeriodicSync()
        } else {
            cancelPeriodicSync()
        }
    }

    // Default to true if WebDAV is configured, so sync actually runs
    fun isSyncEnabled(): Boolean = sharedPreferences.getBoolean("sync_enabled", true) && isWebDAVConfigured()

    fun setAutoSyncEnabled(enabled: Boolean) {
        sharedPreferences.edit().putBoolean("auto_sync_enabled", enabled).apply()
        if (enabled && isSyncEnabled()) {
            schedulePeriodicSync()
        } else {
            cancelPeriodicSync()
        }
    }

    fun isAutoSyncEnabled(): Boolean = sharedPreferences.getBoolean("auto_sync_enabled", true)

    fun setLastSyncTime(time: Long) {
        sharedPreferences.edit().putLong("last_sync_time", time).apply()
    }

    fun getLastSyncTime(): Long = sharedPreferences.getLong("last_sync_time", 0L)

    fun saveWebDAVConfig(url: String, user: String, pass: String) {
        sharedPreferences.edit()
            .putString("webdav_url", url)
            .putString("webdav_user", user)
            .putString("webdav_pass", pass)
            .putBoolean("webdav_configured", true)
            .apply()
        setAutoSyncEnabled(true)
        startSyncNow()
    }

    fun getWebDAVUrl(): String? = sharedPreferences.getString("webdav_url", null)
    fun getWebDAVUser(): String? = sharedPreferences.getString("webdav_user", null)
    fun getWebDAVPass(): String? = sharedPreferences.getString("webdav_pass", null)
    fun isWebDAVConfigured(): Boolean = sharedPreferences.getBoolean("webdav_configured", false)

    fun getMusicDirectoryUri(): String? = sharedPreferences.getString("music_directory_uri", null)
    fun setMusicDirectoryUri(uri: String) {
        sharedPreferences.edit().putString("music_directory_uri", uri).apply()
    }

    fun disconnectWebDAV() {
        sharedPreferences.edit()
            .remove("webdav_url")
            .remove("webdav_user")
            .remove("webdav_pass")
            .putBoolean("webdav_configured", false)
            .apply()
        cancelPeriodicSync()
    }

    fun startImmediateSync(syncType: String? = null) {
        enqueueSync(syncType ?: SYNC_TYPE_TWO_WAY, SYNC_TAG_MANUAL, UNIQUE_SYNC_WORK_NAME)
    }

    fun startSyncNow() {
        startImmediateSync(SYNC_TYPE_TWO_WAY)
    }

    private fun enqueueSync(syncType: String, tag: String, uniqueWorkName: String) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val syncRequest = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(constraints)
            .setInputData(workDataOf("sync_type" to syncType))
            .addTag(tag)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()

        WorkManager.getInstance(context).enqueueUniqueWork(
            uniqueWorkName,
            ExistingWorkPolicy.REPLACE,
            syncRequest
        )
    }

    private fun schedulePeriodicSync() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .setRequiresBatteryNotLow(true)
            .build()

        val periodicSyncRequest = PeriodicWorkRequestBuilder<SyncWorker>(1, TimeUnit.HOURS)
            .setConstraints(constraints)
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
