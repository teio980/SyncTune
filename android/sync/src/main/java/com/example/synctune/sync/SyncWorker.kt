package com.example.synctune.sync

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.documentfile.provider.DocumentFile
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.example.synctune.library.MetadataReader
import com.example.synctune.library.SongDao
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.File
import java.util.Locale
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    private val songDao = SongDao(applicationContext)
    private val metadataReader = MetadataReader()
    private val METADATA_FILE = "sync_metadata.json"

    companion object {
        const val ACTION_SYNC_COMPLETED = "com.example.synctune.ACTION_SYNC_COMPLETED"
    }

    override suspend fun doWork(): Result = coroutineScope {
        updateProgress("Checking connection...", "", 0, 0)
        
        val syncManager = SyncManager(applicationContext)
        val url = syncManager.getWebDAVUrl() ?: return@coroutineScope Result.failure()
        val user = syncManager.getWebDAVUser() ?: ""
        val pass = syncManager.getWebDAVPass() ?: ""
        
        val webDAV = WebDAVHelper(url, user, pass)
        val prefs = applicationContext.getSharedPreferences("SyncTunePrefs", Context.MODE_PRIVATE)
        val rootUriStr = prefs.getString("music_directory_uri", null) ?: return@coroutineScope Result.failure()
        val rootUri = Uri.parse(rootUriStr)
        val musicDir = DocumentFile.fromTreeUri(applicationContext, rootUri) ?: return@coroutineScope Result.failure()

        try {
            updateProgress("Fetching remote metadata...", "", 0, 0)
            val remoteMetadata = fetchRemoteMetadata(webDAV)

            // --- 此处删除了自动上传逻辑，Sync 现在只负责"下载更新" ---

            // 1. 下载/更新逻辑 (严格检查用户设置的本地目录)
            updateProgress("Checking for updates...", "", 0, 0)
            val remoteResult = webDAV.listRemoteFiles()
            if (remoteResult.isSuccess) {
                val remoteFiles = remoteResult.getOrThrow()
                // 获取用户设置目录下的所有物理文件
                val localPhysicalFiles = listLocalFiles(applicationContext, rootUri).associateBy { it.name }
                val currentDbSongs = songDao.getAllSongsSorted("date").associateBy { it.fileName }

                val toDownload = remoteFiles.filter { remote ->
                    val physicalFile = localPhysicalFiles[remote.name]
                    val dbSong = currentDbSongs[remote.name]
                    val remoteTime = remoteMetadata.optLong(remote.name, 0L)

                    if (physicalFile != null) {
                        // 物理文件已存在于用户设置的目录中
                        if (dbSong != null) {
                            // 数据库也有记录，只有云端版本更新时才下载
                            remoteTime > dbSong.modifiedTime
                        } else {
                            // 物理文件在，但数据库没记录（可能是手动拷入的）。直接入库，不下载。
                            metadataReader.readMetadata(applicationContext, physicalFile.uri)?.let { s ->
                                songDao.insertSong(s.copy(modifiedTime = remoteTime, isDirty = false))
                            }
                            false 
                        }
                    } else {
                        // 物理文件完全不存在，需要下载
                        true
                    }
                }.sortedBy { it.modifiedDate }

                toDownload.forEachIndexed { index, remote ->
                    val totalSizeMb = String.format(Locale.US, "%.1f", remote.size / (1024.0 * 1024.0))
                    
                    // 创建文件并开始下载
                    musicDir.createFile(AudioFileValidator.getMimeType(remote.name), remote.name)?.let { newFile ->
                        webDAV.downloadToFile(applicationContext, remote.name, newFile) { bytesRead ->
                            val currentMb = String.format(Locale.US, "%.1f", bytesRead / (1024.0 * 1024.0))
                            updateProgress("Downloading...", remote.name, index + 1, toDownload.size, currentMb, totalSizeMb)
                        }.let { res ->
                            if (res.isSuccess) {
                                metadataReader.readMetadata(applicationContext, newFile.uri)?.let { s ->
                                    val serverVer = remoteMetadata.optLong(remote.name, newFile.lastModified())
                                    val existing = songDao.getSongByHash(s.fileHash)
                                    if (existing != null) {
                                        songDao.updateSong(s.copy(id = existing.id, modifiedTime = serverVer, isDirty = false))
                                    } else {
                                        songDao.insertSong(s.copy(modifiedTime = serverVer, isDirty = false))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 2. 收藏状态双向同步 (LWW)
            updateProgress("Syncing favourites...", "", 0, 0)
            syncFavouritesWithLWW(webDAV)

            applicationContext.sendBroadcast(Intent(ACTION_SYNC_COMPLETED))
            Result.success()
        } catch (e: Exception) {
            Result.failure()
        }
    }

    private suspend fun syncFavouritesWithLWW(helper: WebDAVHelper) {
        val fileName = "favourites_v2.json"
        val tempFile = File(applicationContext.cacheDir, fileName)
        
        val allSongs = songDao.getAllSongsSorted("date")
        val localStateMap = allSongs.associateBy({ it.fileName }, { Pair(it.isFavourite, it.favLastUpdated) }).toMutableMap()

        val remoteJson = if (helper.downloadFile(applicationContext, fileName, DocumentFile.fromFile(applicationContext.cacheDir)).isSuccess) {
            try { JSONObject(tempFile.readText()) } catch (e: Exception) { JSONObject() }
        } else {
            JSONObject()
        }

        val finalStateMap = mutableMapOf<String, Pair<Boolean, Long>>()
        val keys = remoteJson.keys()
        while (keys.hasNext()) {
            val fName = keys.next()
            val obj = remoteJson.getJSONObject(fName)
            val rFav = obj.getBoolean("fav")
            val rTime = obj.getLong("time")
            
            val local = localStateMap[fName]
            if (local != null) {
                if (local.second > rTime) finalStateMap[fName] = local
                else finalStateMap[fName] = Pair(rFav, rTime)
                localStateMap.remove(fName)
            } else {
                finalStateMap[fName] = Pair(rFav, rTime)
            }
        }
        finalStateMap.putAll(localStateMap)

        allSongs.forEach { song ->
            finalStateMap[song.fileName]?.let { final ->
                if (song.isFavourite != final.first) {
                    songDao.updateFavouriteStatusWithTimestamp(song.id, final.first, final.second)
                }
            }
        }

        val uploadJson = JSONObject()
        finalStateMap.forEach { (name, data) ->
            val obj = JSONObject()
            obj.put("fav", data.first)
            obj.put("time", data.second)
            uploadJson.put(name, obj)
        }
        tempFile.writeText(uploadJson.toString())
        helper.uploadFile(applicationContext, DocumentFile.fromFile(tempFile))
    }

    private suspend fun fetchRemoteMetadata(helper: WebDAVHelper): JSONObject {
        val tempFile = File(applicationContext.cacheDir, METADATA_FILE)
        return if (helper.downloadFile(applicationContext, METADATA_FILE, DocumentFile.fromFile(applicationContext.cacheDir)).isSuccess) {
            try { JSONObject(tempFile.readText()) } catch (e: Exception) { JSONObject() }
        } else {
            JSONObject()
        }
    }

    private suspend fun updateProgress(status: String, fName: String, current: Int, total: Int, cSize: String = "0", tSize: String = "0") {
        val data = workDataOf(
            "step_message" to status,
            "file_name" to fName,
            "current" to current,
            "total" to total,
            "current_size" to cSize,
            "total_size" to tSize
        )
        setProgress(data)
        
        val msg = if (fName.isNotEmpty()) {
            if (total > 0) "[$current/$total] $status: $fName" else "$status: $fName"
        } else status
        
        try { setForeground(createForegroundInfo(msg)) } catch (e: Exception) {}
    }

    private fun listLocalFiles(context: Context, treeUri: Uri): List<FileInfo> {
        val rootDoc = DocumentFile.fromTreeUri(context, treeUri) ?: return emptyList()
        val files = mutableListOf<FileInfo>()
        scanDocumentDir(rootDoc, files)
        return files
    }

    private fun scanDocumentDir(dir: DocumentFile, result: MutableList<FileInfo>) {
        dir.listFiles().forEach { file ->
            if (file.isDirectory) {
                scanDocumentDir(file, result)
            } else if (AudioFileValidator.isAudioFile(file.name)) {
                file.name?.let { name -> result.add(FileInfo(name, file.uri)) }
            }
        }
    }

    private data class FileInfo(val name: String, val uri: Uri)

    private fun createForegroundInfo(message: String): ForegroundInfo {
        val channelId = "sync_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(NotificationChannel(channelId, "Sync", NotificationManager.IMPORTANCE_LOW))
        }
        val notification = NotificationCompat.Builder(applicationContext, channelId)
            .setContentTitle("SyncTune Syncing")
            .setContentText(message)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(1001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(1001, notification)
        }
    }
}
