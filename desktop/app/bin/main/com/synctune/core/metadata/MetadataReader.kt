package com.synctune.core.metadata

import com.mpatric.mp3agic.Mp3File
import java.io.File

data class AudioMetadata(
    val title: String?,
    val artist: String?,
    val album: String?,
    val durationSeconds: Long
)

object MetadataReader {
    fun readMetadata(file: File): AudioMetadata {
        return try {
            if (file.extension.lowercase() == "mp3") {
                val mp3file = Mp3File(file.absolutePath)
                val title: String?
                val artist: String?
                val album: String?
                val duration = mp3file.lengthInSeconds

                if (mp3file.hasId3v2Tag()) {
                    val tag = mp3file.id3v2Tag
                    title = tag.title
                    artist = tag.artist
                    album = tag.album
                } else if (mp3file.hasId3v1Tag()) {
                    val tag = mp3file.id3v1Tag
                    title = tag.title
                    artist = tag.artist
                    album = tag.album
                } else {
                    title = file.nameWithoutExtension
                    artist = null
                    album = null
                }
                AudioMetadata(title ?: file.nameWithoutExtension, artist, album, duration)
            } else {
                // Fallback for FLAC/WAV/M4A if mp3agic doesn't support
                AudioMetadata(file.nameWithoutExtension, "Unknown Artist", "Unknown Album", 0L)
            }
        } catch (e: Exception) {
            AudioMetadata(file.nameWithoutExtension, null, null, 0L)
        }
    }
}
