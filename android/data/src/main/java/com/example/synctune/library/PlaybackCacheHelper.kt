package com.example.synctune.library

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase

class PlaybackCacheHelper(context: Context) {

    private val dbHelper = MusicDbHelper(context.applicationContext)

    fun saveCache(songHash: String, filePath: String, position: Long, repeatMode: Int, shuffleMode: Boolean) {
        val db = dbHelper.writableDatabase
        val values = ContentValues().apply {
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_SONG_HASH, songHash)
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_FILE_PATH, filePath)
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_POSITION, position)
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_REPEAT_MODE, repeatMode)
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_SHUFFLE_MODE, if (shuffleMode) 1 else 0)
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT, System.currentTimeMillis())
        }
        
        db.insertWithOnConflict(
            PlaybackCacheContract.TABLE_NAME,
            null,
            values,
            SQLiteDatabase.CONFLICT_REPLACE
        )
    }

    fun getCache(): CacheData? {
        val db = dbHelper.readableDatabase
        val projection = arrayOf(
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_ID,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_SONG_HASH,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_FILE_PATH,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_POSITION,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_REPEAT_MODE,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_SHUFFLE_MODE,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT
        )
        
        val cursor = db.query(
            PlaybackCacheContract.TABLE_NAME,
            projection,
            null,
            null,
            null,
            null,
            "${PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT} DESC",
            "1"
        )
        
        return cursor.use {
            if (it.moveToFirst()) {
                CacheData(
                    id = it.getLong(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_ID)),
                    songHash = it.getString(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_SONG_HASH)),
                    filePath = it.getString(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_FILE_PATH)),
                    position = it.getLong(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_POSITION)),
                    repeatMode = it.getInt(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_REPEAT_MODE)),
                    shuffleMode = it.getInt(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_SHUFFLE_MODE)) == 1,
                    lastPlayedAt = it.getLong(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT)))
            } else {
                null
            }
        }
    }

    data class CacheData(
        val id: Long,
        val songHash: String,
        val filePath: String,
        val position: Long,
        val repeatMode: Int,
        val shuffleMode: Boolean,
        val lastPlayedAt: Long
    )
}
