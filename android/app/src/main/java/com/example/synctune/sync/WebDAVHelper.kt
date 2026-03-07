package com.example.synctune.sync

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import com.thegrizzlylabs.sardineandroid.Sardine
import com.thegrizzlylabs.sardineandroid.impl.OkHttpSardine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.io.OutputStream

class WebDAVHelper(private val url: String, user: String, pass: String) {

    private val sardine: Sardine = OkHttpSardine()

    init {
        sardine.setCredentials(user, pass)
    }

    suspend fun testConnection(): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            sardine.list(url)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun listRemoteFiles(): Result<List<WebDAVFile>> = withContext(Dispatchers.IO) {
        try {
            val resources = sardine.list(url)
            // The first resource is the directory itself
            val files = resources.drop(1)
                .filter { !it.isDirectory && it.name.endsWith(".mp3", ignoreCase = true) }
                .map { WebDAVFile(it.name, it.contentLength, it.path) }
            Result.success(files)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun listAllResources(): Result<List<WebDAVFile>> = withContext(Dispatchers.IO) {
        try {
            val resources = sardine.list(url)
            val files = resources.drop(1)
                .map { WebDAVFile(it.name, it.contentLength, it.path) }
            Result.success(files)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun uploadFile(context: Context, localFile: DocumentFile): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val remoteUrl = if (url.endsWith("/")) url + localFile.name else "$url/${localFile.name}"
            context.contentResolver.openInputStream(localFile.uri)?.use { input ->
                val bytes = input.readBytes()
                sardine.put(remoteUrl, bytes, "audio/mpeg")
            }
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun downloadFile(context: Context, remoteFileName: String, targetDir: DocumentFile): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val remoteUrl = if (url.endsWith("/")) url + remoteFileName else "$url/$remoteFileName"
            val localFile = targetDir.createFile("audio/mpeg", remoteFileName)
                ?: return@withContext Result.failure(Exception("Failed to create local file"))

            sardine.get(remoteUrl).use { input ->
                context.contentResolver.openOutputStream(localFile.uri)?.use { output ->
                    input.copyTo(output)
                }
            }
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun deleteFile(fileName: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val remoteUrl = if (url.endsWith("/")) url + fileName else "$url/$fileName"
            sardine.delete(remoteUrl)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}

data class WebDAVFile(val name: String, val size: Long, val path: String)
