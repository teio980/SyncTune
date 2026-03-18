package com.synctune.core.model

data class Song(
    val fileHash: String,
    var filePath: String,
    var fileName: String,
    var title: String?,
    var artist: String?,
    var album: String?,
    var duration: Long,
    var modifiedTime: Long,
    var isFavourite: Boolean,
    var isDirty: Boolean = false // 新增：用于增量同步标记
)
