package com.example.synctune.library

data class Song(
    val id: Long = 0,
    val title: String,
    val artist: String,
    val album: String,
    val filePath: String,
    val fileName: String,
    val fileHash: String,
    val modifiedTime: Long,
    val isFavourite: Boolean = false,
    val isDirty: Boolean = false,
    val favLastUpdated: Long = 0 // 新增：记录收藏状态最后一次改变的时间
)
