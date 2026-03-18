package com.synctune.core.settings

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.io.File

@Serializable
data class AppSettings(
    val musicFolders: List<String> = emptyList(),
    val webdavUrl: String = "",
    val webdavUser: String = "",
    val webdavPassword: String = "",
    val syncEnabled: Boolean = false,
    val autoSyncEnabled: Boolean = false,
    val lastSyncTime: Long = 0L
)

class SettingsManager(private val file: File) {
    private var settings: AppSettings = AppSettings()

    fun loadSettings() {
        if (file.exists()) {
            val text = file.readText()
            try {
                settings = Json.decodeFromString(text)
            } catch (e: Exception) {
                settings = AppSettings()
                saveSettings()
            }
        } else {
            saveSettings()
        }
    }

    fun saveSettings() {
        file.parentFile?.mkdirs()
        file.writeText(Json.encodeToString(settings))
    }

    fun getMusicFolders(): List<String> = settings.musicFolders

    fun addMusicFolder(path: String) {
        if (path.isNotBlank() && path !in settings.musicFolders) {
            settings = settings.copy(musicFolders = settings.musicFolders + path)
            saveSettings()
        }
    }

    fun removeMusicFolder(path: String) {
        settings = settings.copy(musicFolders = settings.musicFolders.filter { it != path })
        saveSettings()
    }

    fun setWebDav(url: String, user: String, pass: String) {
        settings = settings.copy(webdavUrl = url, webdavUser = user, webdavPassword = pass)
        saveSettings()
    }

    fun getWebDav(): Triple<String, String, String> = Triple(settings.webdavUrl, settings.webdavUser, settings.webdavPassword)

    fun isWebDavConfigured(): Boolean = settings.webdavUrl.isNotBlank()

    fun isAutoSyncEnabled(): Boolean = settings.autoSyncEnabled

    fun setAutoSyncEnabled(enabled: Boolean) {
        settings = settings.copy(autoSyncEnabled = enabled)
        saveSettings()
    }

    fun getLastSyncTime(): Long = settings.lastSyncTime

    fun setLastSyncTime(time: Long) {
        settings = settings.copy(lastSyncTime = time)
        saveSettings()
    }

    fun disconnectWebDav() {
        settings = settings.copy(webdavUrl = "", webdavUser = "", webdavPassword = "")
        saveSettings()
    }
}
