package com.synctune.core.sync

import com.synctune.core.database.SongDao
import com.synctune.core.settings.SettingsManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * 对应 Android 端的 SyncManager
 * 专门负责同步配置的管理 (Delegation to SettingsManager)
 */
class SyncManager(
    private val songDao: SongDao,
    private val settingsManager: SettingsManager
) {
    private val scope = CoroutineScope(Dispatchers.IO)

    fun isAutoSyncEnabled(): Boolean = settingsManager.isAutoSyncEnabled()
    fun setAutoSyncEnabled(enabled: Boolean) = settingsManager.setAutoSyncEnabled(enabled)
    fun getLastSyncTime(): Long = settingsManager.getLastSyncTime()
    fun isWebDavConfigured(): Boolean = settingsManager.isWebDavConfigured()
    fun disconnectWebDav() = settingsManager.disconnectWebDav()

    fun performSync(
        syncType: String,
        onProgress: (SyncWorker.SyncStats) -> Unit,
        onComplete: (SyncWorker.SyncStats) -> Unit
    ) {
        scope.launch {
            val (url, user, pass) = settingsManager.getWebDav()
            if (url.isBlank()) {
                onComplete(SyncWorker.SyncStats(isCompleted = true, stepMessage = "Not configured"))
                return@launch
            }

            val client = WebDavClient(url, user, pass)
            val worker = SyncWorker(songDao, client)
            val folders = settingsManager.getMusicFolders()

            try {
                val stats = worker.doWork(syncType, folders, onProgress)
                settingsManager.setLastSyncTime(System.currentTimeMillis())
                onComplete(stats)
            } catch (e: Exception) {
                onComplete(SyncWorker.SyncStats(isCompleted = true, stepMessage = "Error: ${e.message}"))
            }
        }
    }
}
