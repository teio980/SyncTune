package com.example.synctune.library

data class Song(
    val id: Long = 0,
    val title: String,
    val artist: String,
    val album: String,
    val filePath: String,
    val fileName: String, // 新增：保存真实文件名用于匹配
    val fileHash: String,
    val modifiedTime: Long,
    val isFavourite: Boolean = false
)
