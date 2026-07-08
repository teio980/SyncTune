package com.synctune.core.sync

import com.synctune.core.database.SongDao
import com.synctune.core.model.Song
import com.synctune.core.metadata.MetadataReader
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.long
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

/**
 * 对应 Android 端的 SyncWorker
 * 负责核心同步逻辑
 */
class SyncWorker(
    private val songDao: SongDao,
    private val client: WebDavClient
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val METADATA_FILE = "sync_metadata.json"
    private val MAX_CONCURRENT_TRANSFERS = 3

    data class SyncStats(
        val step: Int = 0,
        val totalSteps: Int = 5,
        val stepMessage: String = "",
        val fileName: String = "",
        val current: Int = 0,
        val total: Int = 0,
        val uploaded: Int = 0,
        val downloaded: Int = 0,
        val isCompleted: Boolean = false
    )

    suspend fun doWork(syncType: String, musicFolders: List<String>, onProgress: (SyncStats) -> Unit): SyncStats = coroutineScope {
        var stats = SyncStats()
        
        try {
            // 1. 获取远程元数据
            stats = stats.copy(step = 1, stepMessage = "Fetching metadata...")
            onProgress(stats)
            val remoteMetadata = fetchRemoteMetadata()

            // 2. 上传脏数据 (Android isDirty 逻辑)
            if (syncType == "UPLOAD" || syncType == "TWO_WAY") {
                val dirtySongs = songDao.getAllSongs().filter { it.isDirty }
                if (dirtySongs.isNotEmpty()) {
                    stats = stats.copy(step = 2, stepMessage = "Uploading...", total = dirtySongs.size)
                    onProgress(stats)
                    
                    val completed = AtomicInteger(0)
                    val uploadedCount = AtomicInteger(0)
                    val semaphore = Semaphore(MAX_CONCURRENT_TRANSFERS)
                    val updatedMetadata = remoteMetadata.toMutableMap()

                    dirtySongs.map { song ->
                        async {
                            semaphore.withPermit {
                                stats = stats.copy(fileName = song.fileName, current = completed.incrementAndGet())
                                onProgress(stats)
                                
                                val file = File(song.filePath)
                                if (file.exists()) {
                                    if (client.uploadFile(song.fileName, file.readBytes())) {
                                        val newVersion = System.currentTimeMillis()
                                        songDao.updateSong(song.copy(isDirty = false, modifiedTime = newVersion))
                                        updatedMetadata[song.fileName] = kotlinx.serialization.json.JsonPrimitive(newVersion)
                                        uploadedCount.incrementAndGet()
                                    }
                                }
                            }
                        }
                    }.awaitAll()
                    saveRemoteMetadata(updatedMetadata)
                    stats = stats.copy(uploaded = uploadedCount.get())
                }
            }

            // 3. 差异化下载 (Android 版本对比逻辑)
            if (syncType == "DOWNLOAD" || syncType == "TWO_WAY") {
                stats = stats.copy(step = 3, stepMessage = "Fetching remote list...")
                onProgress(stats)
                
                val remoteFiles = client.listFiles()
                val downloadDir = musicFolders.firstOrNull()?.let { File(it) }
                
                if (downloadDir != null) {
                    val localSongs = songDao.getAllSongs().associateBy { it.fileName }
                    val toDownload = remoteFiles.filter { r ->
                        if (r.isDirectory || !AudioFileValidator.isAudioFile(r.name)) return@filter false
                        val serverVersion = remoteMetadata[r.name]?.jsonPrimitive?.long ?: 0L
                        val localSong = localSongs[r.name]
                        localSong == null || serverVersion > localSong.modifiedTime
                    }.sortedBy { it.modifiedDate }

                    if (toDownload.isNotEmpty()) {
                        stats = stats.copy(step = 4, stepMessage = "Downloading...", total = toDownload.size, current = 0)
                        onProgress(stats)
                        
                        val completed = AtomicInteger(0)
                        val downloadedCount = AtomicInteger(0)
                        val semaphore = Semaphore(MAX_CONCURRENT_TRANSFERS)

                        toDownload.map { r ->
                            async {
                                semaphore.withPermit {
                                    stats = stats.copy(fileName = r.name, current = completed.incrementAndGet())
                                    onProgress(stats)
                                    val targetFile = File(downloadDir, r.name)
                                    if (client.downloadFile(r.name, targetFile)) {
                                        val md = MetadataReader.readMetadata(targetFile)
                                        val serverVer = remoteMetadata[r.name]?.jsonPrimitive?.long ?: System.currentTimeMillis()
                                        val existing = localSongs[r.name]
                                        val newSong = Song(
                                            fileHash = existing?.fileHash ?: com.synctune.core.hash.HashUtil.computeHash(targetFile),
                                            filePath = targetFile.absolutePath,
                                            fileName = r.name,
                                            title = md.title, artist = md.artist, album = md.album, duration = md.durationSeconds,
                                            modifiedTime = serverVer, isFavourite = existing?.isFavourite ?: false, isDirty = false
                                        )
                                        if (existing != null) songDao.updateSong(newSong) else songDao.insertSong(newSong)
                                        downloadedCount.incrementAndGet()
                                    }
                                }
                            }
                        }.awaitAll()
                        stats = stats.copy(downloaded = downloadedCount.get())
                    }
                }
            }

            // 4. 收藏同步
            stats = stats.copy(step = 5, stepMessage = "Finalizing Favourites...")
            onProgress(stats)
            syncFavourites()

            stats = stats.copy(isCompleted = true, stepMessage = "Sync complete")
            onProgress(stats)
            stats
        } catch (e: Exception) {
            stats.copy(isCompleted = true, stepMessage = "Error: ${e.message}")
        }
    }

    private fun fetchRemoteMetadata(): Map<String, kotlinx.serialization.json.JsonElement> {
        val tempFile = File(System.getProperty("java.io.tmpdir"), METADATA_FILE)
        return if (client.downloadFile(METADATA_FILE, tempFile)) {
            try { json.decodeFromString<Map<String, kotlinx.serialization.json.JsonElement>>(tempFile.readText()) } catch (e: Exception) { emptyMap() }
        } else emptyMap()
    }

    private fun saveRemoteMetadata(metadata: Map<String, kotlinx.serialization.json.JsonElement>) {
        val tempFile = File(System.getProperty("java.io.tmpdir"), METADATA_FILE)
        tempFile.writeText(json.encodeToString(metadata))
        client.uploadFile(METADATA_FILE, tempFile.readBytes())
    }

    private fun syncFavourites() {
        val fileName = "favourites.json"
        val tempFile = File(System.getProperty("java.io.tmpdir"), fileName)
        if (client.downloadFile(fileName, tempFile)) {
            try {
                val remoteMap = json.decodeFromString<Map<String, Boolean>>(tempFile.readText())
                songDao.getAllSongs().forEach { song ->
                    val isFav = remoteMap[song.fileHash] ?: false
                    if (song.isFavourite != isFav) songDao.updateFavourite(song.fileHash, isFav)
                }
            } catch (e: Exception) {}
        }
        val map = songDao.getFavouriteHashes().associateWith { true }
        client.uploadFile(fileName, json.encodeToString(map).toByteArray())
    }
}
