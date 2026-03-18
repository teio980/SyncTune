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
            val fileSize = documentFile?.length() ?: 0L
            
            val title = if (titleFromTag.isNullOrBlank()) {
                if (fileName.contains('.')) fileName.substringBeforeLast('.') else fileName
            } else titleFromTag
            
            val artist = if (artistFromTag.isNullOrBlank()) "Unknown Artist" else artistFromTag
            val album = if (albumFromTag.isNullOrBlank()) "Unknown Album" else albumFromTag

            // 核心修复：获取跨设备稳定的 Hash
            val fileHash = getUriHash(context, uri, fileName, fileSize)

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

    private fun getUriHash(context: Context, uri: Uri, fileName: String, fileSize: Long): String {
        val md = MessageDigest.getInstance("MD5")
        try {
            context.contentResolver.openInputStream(uri)?.use { inputStream ->
                val dataBytes = ByteArray(1024)
                var nread: Int
                var totalRead = 0
                while (inputStream.read(dataBytes).also { nread = it } != -1 && totalRead < 8192) {
                    md.update(dataBytes, 0, nread)
                    totalRead += nread
                }
            }
            val mdbytes = md.digest()
            val sb = StringBuilder()
            for (i in mdbytes.indices) {
                sb.append(Integer.toString((mdbytes[i].toInt() and 0xff) + 0x100, 16).substring(1))
            }
            return sb.toString()
        } catch (e: Exception) {
            // 如果读取失败，改用 文件名 + 大小 的组合 Hash，这在多端是唯一的
            return "fallback_${fileName}_${fileSize}".hashCode().toString()
        }
    }
    
    fun readMetadata(context: Context, file: File): Song? {
        return readMetadata(context, Uri.fromFile(file))
    }
}
