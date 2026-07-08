package com.example.synctune.library

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import org.jaudiotagger.audio.AudioFileIO
import org.jaudiotagger.tag.images.ArtworkFactory
import org.jaudiotagger.tag.reference.PictureTypes
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

/**
 * 专门处理封面修改的核心类
 * 采用"临时文件-原子写回"策略，解决 SAF 权限下的文件损坏问题
 */
class CoverEditor(private val context: Context) {

    fun updateCover(song: Song, imageUri: Uri): Result<Unit> {
        return try {
            val imageBytes = processImage(imageUri) ?: return Result.failure(Exception("Image processing failed"))
            val songUri = Uri.parse(song.filePath)
            val extension = song.fileName.substringAfterLast(".", "mp3")
            
            // 1. 创建临时文件
            val tmpFile = File(context.cacheDir, "cover_edit_${System.currentTimeMillis()}.$extension")
            
            // 2. 将原音频内容拷贝到临时文件
            context.contentResolver.openInputStream(songUri)?.use { input ->
                tmpFile.outputStream().use { output -> input.copyTo(output) }
            } ?: throw Exception("Cannot read source file")

            // 3. 使用 JAudioTagger 修改临时文件中的 Tag
            org.jaudiotagger.tag.TagOptionSingleton.getInstance().isAndroid = true
            val audioFile = AudioFileIO.read(tmpFile)
            val tag = audioFile.tag ?: audioFile.createDefaultTag()
            
            tag.deleteArtworkField()
            val artwork = ArtworkFactory.getNew()
            artwork.binaryData = imageBytes
            artwork.mimeType = "image/jpeg"
            artwork.pictureType = PictureTypes.DEFAULT_ID
            tag.setField(artwork)
            audioFile.commit()

            // 4. 将修改后的临时文件写回原路径 (原子写回模式)
            context.contentResolver.openFileDescriptor(songUri, "rwt")?.use { pfd ->
                FileOutputStream(pfd.fileDescriptor).use { fos ->
                    tmpFile.inputStream().use { fis -> fis.copyTo(fos) }
                }
            } ?: throw Exception("Cannot write back to source")

            tmpFile.delete()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun processImage(uri: Uri): ByteArray? {
        return context.contentResolver.openInputStream(uri)?.use { input ->
            val original = BitmapFactory.decodeStream(input) ?: return null

            // 裁剪为 1:1
            val size = Math.min(original.width, original.height)
            val x = (original.width - size) / 2
            val y = (original.height - size) / 2
            val square = Bitmap.createBitmap(original, x, y, size, size)

            // 缩放至 800x800
            val scaled = Bitmap.createScaledBitmap(square, 800, 800, true)
            
            val baos = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 85, baos)
            val bytes = baos.toByteArray()
            
            if (square != original) square.recycle()
            scaled.recycle()
            original.recycle()
            bytes
        }
    }
}
