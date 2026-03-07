package com.example.synctune.library

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.security.MessageDigest

class MetadataReader {

    fun readMetadata(context: Context, uri: Uri): Song? {
        val retriever = MediaMetadataRetriever()
        try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                retriever.setDataSource(pfd.fileDescriptor)
            }

            val titleFromTag = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
            val artistFromTag = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
            val albumFromTag = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)

            val documentFile = DocumentFile.fromSingleUri(context, uri)
            val fileName = documentFile?.name ?: "Unknown"
            
            val title = if (titleFromTag.isNullOrBlank()) {
                if (fileName.contains('.')) fileName.substringBeforeLast('.') else fileName
            } else titleFromTag
            
            val artist = if (artistFromTag.isNullOrBlank()) "Unknown Artist" else artistFromTag
            val album = if (albumFromTag.isNullOrBlank()) "Unknown Album" else albumFromTag

            // 对于 URI，我们尝试获取文件大小或最后修改时间作为哈希的一部分，或者读取部分内容
            val fileHash = getUriHash(context, uri)

            return Song(
                title = title,
                artist = artist,
                album = album,
                filePath = uri.toString(),
                fileName = fileName,
                fileHash = fileHash,
                modifiedTime = documentFile?.lastModified() ?: 0L
            )
        } catch (e: Exception) {
            return null
        } finally {
            retriever.release()
        }
    }

    private fun getUriHash(context: Context, uri: Uri): String {
        val md = MessageDigest.getInstance("MD5")
        try {
            context.contentResolver.openInputStream(uri)?.use { inputStream ->
                val dataBytes = ByteArray(1024)
                var nread: Int
                // 只读取前 8KB 进行哈希以保证性能，或者根据需要调整
                var totalRead = 0
                while (inputStream.read(dataBytes).also { nread = it } != -1 && totalRead < 8192) {
                    md.update(dataBytes, 0, nread)
                    totalRead += nread
                }
            }
        } catch (e: Exception) {
            return uri.toString().hashCode().toString()
        }
        val mdbytes = md.digest()
        val sb = StringBuilder()
        for (i in mdbytes.indices) {
            sb.append(Integer.toString((mdbytes[i].toInt() and 0xff) + 0x100, 16).substring(1))
        }
        return sb.toString()
    }
    
    // 保留旧的 File 方法以防万一，但内部转为 URI 处理
    fun readMetadata(context: Context, file: File): Song? {
        return readMetadata(context, Uri.fromFile(file))
    }
}
