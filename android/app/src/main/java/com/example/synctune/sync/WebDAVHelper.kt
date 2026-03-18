package com.example.synctune.sync

import android.content.Context
import androidx.documentfile.provider.DocumentFile
import com.thegrizzlylabs.sardineandroid.Sardine
import com.thegrizzlylabs.sardineandroid.impl.OkHttpSardine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Date

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

    suspend fun uploadFile(context: Context, localFile: DocumentFile): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val fileName = localFile.name ?: return@withContext Result.failure<Unit>(Exception("File name is null"))
            val remoteUrl = if (url.endsWith("/")) url + fileName else "$url/$fileName"

            val tempFile = File(context.cacheDir, "up_$fileName")
            try {
                context.contentResolver.openInputStream(localFile.uri)?.use { input ->
                    tempFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                val mimeType = AudioFileValidator.getMimeType(fileName)
                sardine.put(remoteUrl, tempFile, mimeType)
                Result.success(Unit)
            } finally {
                if (tempFile.exists()) tempFile.delete()
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun downloadToFile(
        context: Context, 
        remoteFileName: String, 
        targetFile: DocumentFile,
        onProgress: (suspend (Long) -> Unit)? = null
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val remoteUrl = if (url.endsWith("/")) url + remoteFileName else "$url/$remoteFileName"
            sardine.get(remoteUrl).use { input ->
                context.contentResolver.openOutputStream(targetFile.uri)?.use { output ->
                    val buffer = ByteArray(8192)
                    var bytesRead: Int
                    var totalRead: Long = 0
                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        output.write(buffer, 0, bytesRead)
                        totalRead += bytesRead
                        onProgress?.invoke(totalRead)
                    }
                }
            }
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun downloadFile(context: Context, remoteFileName: String, targetDir: DocumentFile): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val mimeType = AudioFileValidator.getMimeType(remoteFileName)
            val existing = targetDir.findFile(remoteFileName)
            val localFile = existing ?: targetDir.createFile(mimeType, remoteFileName)
                ?: return@withContext Result.failure<Unit>(Exception("Failed to create local file"))
            downloadToFile(context, remoteFileName, localFile)
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

    suspend fun listRemoteFiles(): Result<List<WebDAVFile>> = withContext(Dispatchers.IO) {
        try {
            val resources = sardine.list(url)
            val files = resources
                .filter { !it.isDirectory && AudioFileValidator.isAudioFile(it.name) }
                .map { WebDAVFile(it.name, it.contentLength, it.path, it.modified ?: Date(0)) }
            Result.success(files)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}

data class WebDAVFile(val name: String, val size: Long, val path: String, val modifiedDate: Date)
