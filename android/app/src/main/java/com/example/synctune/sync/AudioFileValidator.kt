package com.example.synctune.sync

object AudioFileValidator {
    private val supportedExtensions = setOf("mp3", "flac", "wav", "m4a", "aac", "ogg", "opus")

    fun isAudioFile(fileName: String?): Boolean {
        if (fileName == null) return false
        val extension = fileName.substringAfterLast('.', "").lowercase()
        return supportedExtensions.contains(extension)
    }

    fun getMimeType(fileName: String?): String {
        if (fileName == null) return "application/octet-stream"
        return when (fileName.substringAfterLast('.', "").lowercase()) {
            "mp3" -> "audio/mpeg"
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            "m4a" -> "audio/mp4"
            "aac" -> "audio/aac"
            "ogg" -> "audio/ogg"
            "opus" -> "audio/opus"
            else -> "audio/*"
        }
    }
}
