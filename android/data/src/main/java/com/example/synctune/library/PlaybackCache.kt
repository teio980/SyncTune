package com.example.synctune.library

import android.content.Context
import android.content.SharedPreferences

object PlaybackCache {
    private const val PREFS_NAME = "playback_cache"
    private const val KEY_SONG_HASH = "song_hash"
    private const val KEY_FILE_PATH = "file_path"
    private const val KEY_POSITION = "position"
    private const val KEY_REPEAT_MODE = "repeat_mode"
    private const val KEY_SHUFFLE_MODE = "shuffle_mode"

    private fun getPrefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun save(context: Context, songHash: String, filePath: String, position: Long, repeatMode: Int, shuffleMode: Boolean) {
        getPrefs(context).edit()
            .putString(KEY_SONG_HASH, songHash)
            .putString(KEY_FILE_PATH, filePath)
            .putLong(KEY_POSITION, position)
            .putInt(KEY_REPEAT_MODE, repeatMode)
            .putBoolean(KEY_SHUFFLE_MODE, shuffleMode)
            .apply()
    }

    fun get(context: Context): CacheData? {
        val prefs = getPrefs(context)
        val songHash = prefs.getString(KEY_SONG_HASH, null) ?: return null
        return CacheData(
            songHash = songHash,
            filePath = prefs.getString(KEY_FILE_PATH, "") ?: "",
            position = prefs.getLong(KEY_POSITION, 0),
            repeatMode = prefs.getInt(KEY_REPEAT_MODE, 0),
            shuffleMode = prefs.getBoolean(KEY_SHUFFLE_MODE, false)
        )
    }

    data class CacheData(
        val songHash: String,
        val filePath: String,
        val position: Long,
        val repeatMode: Int,
        val shuffleMode: Boolean
    )
}
