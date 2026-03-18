package com.example.synctune.library

import android.provider.BaseColumns

object SongContract {
    object SongEntry : BaseColumns {
        const val TABLE_NAME = "songs"
        const val COLUMN_NAME_ID = "id"
        const val COLUMN_NAME_TITLE = "title"
        const val COLUMN_NAME_ARTIST = "artist"
        const val COLUMN_NAME_ALBUM = "album"
        const val COLUMN_NAME_FILE_PATH = "file_path"
        const val COLUMN_NAME_FILE_NAME = "file_name"
        const val COLUMN_NAME_FILE_HASH = "file_hash"
        const val COLUMN_NAME_MODIFIED_TIME = "modified_time"
        const val COLUMN_NAME_IS_FAVOURITE = "is_favourite"
        const val COLUMN_NAME_IS_DIRTY = "is_dirty"
        const val COLUMN_NAME_FAV_LAST_UPDATED = "fav_last_updated" // 新增：收藏状态最后修改时间
    }
}
