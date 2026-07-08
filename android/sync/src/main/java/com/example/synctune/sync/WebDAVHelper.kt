package com.example.synctune.sync

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import com.thegrizzlylabs.sardineandroid.Sardine
import com.thegrizzlylabs.sardineandroid.impl.OkHttpSardine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.RequestBody.Companion.asRequestBody
import okio.*
import java.io.File
import java.io.IOException
import java.util.Date
import java.util.concurrent.TimeUnit

class WebDAVHelper(private val url: String, private val user: String, private val pass: String) {

    private val sardine: Sardine = OkHttpSardine()
    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val request = chain.request().newBuilder()
                .header("Authorization", Credentials.basic(user, pass))
                .header("Cache-Control", "no-cache")
                .header("Pragma", "no-cache")
                .build()
            chain.proceed(request)
        }
        .build()

    init {
        sardine.setCredentials(user, pass)
    }

    private fun getRemoteUrl(fileName: String): String {
        val base = url.toHttpUrlOrNull() ?: throw Exception("Invalid WebDAV URL: $url")
        return base.newBuilder().addPathSegment(fileName).build().toString()
    }

    suspend fun testConnection(): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            sardine.list(url)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * 上传文件新方案：
     * 1. 显式删除远程旧文件（防止某些服务器 PUT 不覆盖的问题）
     * 2. 使用 OkHttp 强制 PUT 上传，并禁用所有缓存
     */
    suspend fun uploadFile(
        context: Context, 
        localFile: DocumentFile,
        onProgress: (suspend (Long) -> Unit)? = null
    ): Result<Unit> = withContext(Dispatchers.IO) {
        var tempFile: File? = null
        try {
            val fileName = localFile.name ?: return@withContext Result.failure(Exception("File name is null"))
            val remoteUrl = getRemoteUrl(fileName)
            
            // 1. 尝试删除旧文件
            try { sardine.delete(remoteUrl) } catch (e: Exception) {}

            // 2. 准备上传数据
            tempFile = File(context.cacheDir, "up_${System.currentTimeMillis()}.tmp")
            context.contentResolver.openInputStream(localFile.uri)?.use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            } ?: throw Exception("Read local file failed")

            val mediaType = AudioFileValidator.getMimeType(fileName).toMediaTypeOrNull()
            val fileBody = tempFile.asRequestBody(mediaType)
            
            val requestBody = if (onProgress != null) {
                ProgressRequestBody(fileBody, onProgress)
            } else {
                fileBody
            }

            val request = Request.Builder()
                .url(remoteUrl)
                .put(requestBody)
                .header("Overwrite", "T")
                .header("Cache-Control", "no-cache")
                .build()

            // 3. 执行物理上传
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    Result.success(Unit)
                } else {
                    throw Exception("Upload failed: HTTP ${response.code} ${response.message}")
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
            Result.failure(e)
        } finally {
            tempFile?.delete()
        }
    }

    suspend fun downloadToFile(
        context: Context, 
        remoteFileName: String, 
        targetFile: DocumentFile,
        onProgress: (suspend (Long) -> Unit)? = null
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val remoteUrl = getRemoteUrl(remoteFileName)
            val request = Request.Builder()
                .url(remoteUrl)
                .header("Cache-Control", "no-cache")
                .get()
                .build()
            
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) throw Exception("Download failed: ${response.code}")
                
                val body = response.body ?: throw Exception("Empty body")
                context.contentResolver.openOutputStream(targetFile.uri)?.use { output ->
                    val buffer = ByteArray(8192)
                    var bytesRead: Int
                    var totalRead: Long = 0
                    val source = body.source()
                    while (source.read(buffer).also { bytesRead = it } != -1) {
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

    suspend fun listRemoteFiles(): Result<List<WebDAVFile>> = withContext(Dispatchers.IO) {
        try {
            val resources = sardine.list(url)
            val files = resources
                .filter { it != null && !it.isDirectory && AudioFileValidator.isAudioFile(it.name ?: "") }
                .map { WebDAVFile(it.name ?: "", it.contentLength, it.path ?: "", it.modified ?: Date(0)) }
            Result.success(files)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun deleteFile(fileName: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val remoteUrl = getRemoteUrl(fileName)
            sardine.delete(remoteUrl)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private class ProgressRequestBody(
        private val requestBody: RequestBody,
        private val onProgress: suspend (Long) -> Unit
    ) : RequestBody() {
        override fun contentType(): MediaType? = requestBody.contentType()
        override fun contentLength(): Long = try { requestBody.contentLength() } catch (e: IOException) { -1 }

        @Throws(IOException::class)
        override fun writeTo(sink: BufferedSink) {
            val countingSink = object : ForwardingSink(sink) {
                private var bytesWritten = 0L
                override fun write(source: Buffer, byteCount: Long) {
                    super.write(source, byteCount)
                    bytesWritten += byteCount
                    runBlocking { onProgress(bytesWritten) }
                }
            }
            val bufferedSink = countingSink.buffer()
            requestBody.writeTo(bufferedSink)
            bufferedSink.flush()
        }

        private fun runBlocking(block: suspend () -> Unit) {
            kotlinx.coroutines.runBlocking { block() }
        }
    }
}

data class WebDAVFile(val name: String, val size: Long, val path: String, val modifiedDate: Date)
