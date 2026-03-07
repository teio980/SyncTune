package com.example.synctune.storage

interface StorageAdapter {
    fun uploadFile(path: String)
    fun downloadFile(path: String)
}
