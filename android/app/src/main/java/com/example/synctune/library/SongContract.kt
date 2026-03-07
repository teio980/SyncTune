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
        const val COLUMN_NAME_FILE_NAME = "file_name" // 新增：真实文件名列
        const val COLUMN_NAME_FILE_HASH = "file_hash"
        const val COLUMN_NAME_MODIFIED_TIME = "modified_time"
        const val COLUMN_NAME_IS_FAVOURITE = "is_favourite"
    }
}
