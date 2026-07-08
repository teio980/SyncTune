package com.example.synctune.library

import android.provider.BaseColumns

object PlaybackCacheContract {
    const val TABLE_NAME = "playback_cache"
    
    object CacheEntry : BaseColumns {
        const val COLUMN_NAME_ID = "id"
        const val COLUMN_NAME_SONG_HASH = "song_hash"
        const val COLUMN_NAME_FILE_PATH = "file_path"
        const val COLUMN_NAME_POSITION = "position"
        const val COLUMN_NAME_REPEAT_MODE = "repeat_mode"
        const val COLUMN_NAME_SHUFFLE_MODE = "shuffle_mode"
        const val COLUMN_NAME_LAST_PLAYED_AT = "last_played_at"
    }
}
