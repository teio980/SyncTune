package com.synctune.core.sync

import com.synctune.core.database.SongDao
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

class FavouriteSyncManager(
    private val songDao: SongDao
) {
    fun pullFavourites(client: WebDavClient, tempDir: File): Boolean {
        val tmp = File(tempDir, "favourites.json")
        val ok = client.downloadFile("favourites.json", tmp)
        if (!ok) return false
        val text = tmp.readText()
        val map = Json.decodeFromString<Map<String, Boolean>>(text)
        if (map.isNotEmpty()) {
            val hashes = map.filterValues { it }.keys
            if (hashes.isNotEmpty()) {
                updateFavouritesBulk(hashes)
            }
        }
        return true
    }

    fun pushFavourites(client: WebDavClient): Boolean {
        val favs = songDao.getFavouriteHashes()
        val map = favs.associateWith { true }
        val json = Json.encodeToString(map)
        return client.uploadFile("favourites.json", json.toByteArray())
    }

    private fun updateFavouritesBulk(hashes: Set<String>) {
        hashes.forEach { h -> songDao.updateFavourite(h, true) }
    }
}
