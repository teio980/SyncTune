package com.example.synctune.sync

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.documentfile.provider.DocumentFile
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import com.example.synctune.R
import com.example.synctune.library.SongDao
import org.json.JSONObject
import java.io.File

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val syncManager = SyncManager(applicationContext)
        val url = syncManager.getWebDAVUrl() ?: return Result.failure()
        val user = syncManager.getWebDAVUser() ?: return Result.failure()
        val pass = syncManager.getWebDAVPass() ?: return Result.failure()
        
        val webDAVHelper = WebDAVHelper(url, user, pass)
        
        val prefs = applicationContext.getSharedPreferences("SyncTunePrefs", Context.MODE_PRIVATE)
        val savedUriString = prefs.getString("music_directory_uri", null) ?: return Result.failure()
        val musicDir = DocumentFile.fromTreeUri(applicationContext, Uri.parse(savedUriString)) ?: return Result.failure()

        val syncType = inputData.getString("sync_type") ?: "TWO_WAY"

        try {
            setForeground(createForegroundInfo())
        } catch (e: Exception) {
            e.printStackTrace()
        }

        return try {
            val localFiles = getLocalMp3Files(musicDir)
            val remoteFilesResult = webDAVHelper.listRemoteFiles()
            
            if (remoteFilesResult.isSuccess) {
                val remoteFiles = remoteFilesResult.getOrNull() ?: emptyList()
                
                when (syncType) {
                    "UPLOAD" -> uploadMissing(webDAVHelper, localFiles, remoteFiles)
                    "DOWNLOAD" -> downloadMissing(webDAVHelper, localFiles, remoteFiles, musicDir)
                    else -> {
                        uploadMissing(webDAVHelper, localFiles, remoteFiles)
                        downloadMissing(webDAVHelper, localFiles, remoteFiles, musicDir)
                    }
                }

                // 使用哈希同步收藏状态
                syncFavouritesMetadata(webDAVHelper)

                syncManager.setLastSyncTime(System.currentTimeMillis())
                Result.success()
            } else {
                Result.retry()
            }
        } catch (e: Exception) {
            Result.failure()
        }
    }

    private suspend fun syncFavouritesMetadata(helper: WebDAVHelper) {
        val songDao = SongDao(applicationContext)
        val metadataFileName = "favourites.json"
        val tempFile = File(applicationContext.cacheDir, metadataFileName)

        // 1. 下载云端哈希列表
        val remoteResourcesResult = helper.listAllResources()
        val remoteResources = remoteResourcesResult.getOrNull() ?: emptyList()
        val remoteMetadataFile = remoteResources.find { it.name == metadataFileName }

        if (remoteMetadataFile != null) {
            val downloadResult = helper.downloadFile(applicationContext, metadataFileName, DocumentFile.fromFile(applicationContext.cacheDir))
            if (downloadResult.isSuccess && tempFile.exists()) {
                try {
                    val json = JSONObject(tempFile.readText())
                    val keys = json.keys()
                    while (keys.hasNext()) {
                        val fileHash = keys.next()
                        val isFav = json.optBoolean(fileHash, false)
                        songDao.updateFavouriteByHash(fileHash, isFav)
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }

        // 2. 上传本地最新哈希列表
        val allSongs = songDao.getAllSongs()
        val favJson = JSONObject()
        allSongs.forEach { song ->
            if (song.fileHash.isNotEmpty()) {
                favJson.put(song.fileHash, song.isFavourite)
            }
        }

        try {
            tempFile.writeText(favJson.toString())
            helper.uploadFile(applicationContext, DocumentFile.fromFile(tempFile))
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private suspend fun uploadMissing(helper: WebDAVHelper, local: List<DocumentFile>, remote: List<WebDAVFile>) {
        val toUpload = local.filter { l -> remote.none { r -> r.name == l.name } }
        toUpload.forEachIndexed { index, file ->
            setProgress(Data.Builder()
                .putString("file_name", file.name)
                .putInt("current", index + 1)
                .putInt("total", toUpload.size)
                .build())
            helper.uploadFile(applicationContext, file)
        }
    }

    private suspend fun downloadMissing(helper: WebDAVHelper, local: List<DocumentFile>, remote: List<WebDAVFile>, targetDir: DocumentFile) {
        val toDownload = remote.filter { r -> local.none { l -> l.name == r.name } }
        toDownload.forEachIndexed { index, file ->
            setProgress(Data.Builder()
                .putString("file_name", file.name)
                .putInt("current", index + 1)
                .putInt("total", toDownload.size)
                .build())
            helper.downloadFile(applicationContext, file.name, targetDir)
        }
    }

    private fun getLocalMp3Files(rootDoc: DocumentFile): List<DocumentFile> {
        val result = mutableListOf<DocumentFile>()
        fun scan(dir: DocumentFile) {
            dir.listFiles().forEach { file ->
                if (file.isDirectory) scan(file)
                else if (file.name?.endsWith(".mp3", true) == true) result.add(file)
            }
        }
        scan(rootDoc)
        return result
    }

    private fun createForegroundInfo(): ForegroundInfo {
        val channelId = "sync_channel"
        val title = "SyncTune 正在同步音乐"
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "Music Sync", NotificationManager.IMPORTANCE_LOW)
            val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(applicationContext, channelId)
            .setContentTitle(title)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(1001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(1001, notification)
        }
    }
}
