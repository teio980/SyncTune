package com.synctune.core.hash

import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import kotlin.math.min

object HashUtil {
    fun computeHash(file: File): String {
        val md = MessageDigest.getInstance("MD5")
        FileInputStream(file).use { fis ->
            val buffer = ByteArray(8192)
            val read = fis.read(buffer, 0, buffer.size)
            if (read > 0) md.update(buffer, 0, read)
        }
        val sizeBytes = ByteArray(8)
        val size = file.length()
        for (i in 0 until 8) {
            sizeBytes[7 - i] = ((size ushr (8 * i)) and 0xFF).toByte()
        }
        md.update(sizeBytes)
        val bytes = md.digest()
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
