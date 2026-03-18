package com.example.synctune.sync

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import androidx.core.app.NotificationCompat
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

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    private val songDao = SongDao(applicationContext)
    private val metadataReader = MetadataReader()
    private val METADATA_FILE = "sync_metadata.json"

    companion object {
        const val ACTION_SYNC_COMPLETED = "com.example.synctune.ACTION_SYNC_COMPLETED"
    }

    override suspend fun doWork(): Result = coroutineScope {
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
            val remoteMetadata = fetchRemoteMetadata(webDAV)

            // 1. 上传逻辑
            val dirtySongs = songDao.getAllSongsSorted().filter { it.isDirty }
            dirtySongs.forEach { song ->
                DocumentFile.fromSingleUri(applicationContext, Uri.parse(song.filePath))?.let { file ->
                    if (webDAV.uploadFile(applicationContext, file).isSuccess) {
                        val newVersion = System.currentTimeMillis()
                        songDao.updateSong(song.copy(isDirty = false, modifiedTime = newVersion))
                        remoteMetadata.put(song.fileName, newVersion)
                    }
                }
            }
            if (dirtySongs.isNotEmpty()) uploadRemoteMetadata(webDAV, remoteMetadata)

            // 2. 下载逻辑
            val remoteResult = webDAV.listRemoteFiles()
            if (remoteResult.isSuccess) {
                val remoteFiles = remoteResult.getOrThrow()
                val localFiles = listLocalFiles(applicationContext, rootUri).associateBy { it.name }
                val currentLocalSongs = songDao.getAllSongsSorted().associateBy { it.fileName }

                val toDownload = remoteFiles.filter { remote ->
                    val localSong = currentLocalSongs[remote.name]
                    localSong == null || remoteMetadata.optLong(remote.name, 0L) > localSong.modifiedTime
                }.sortedBy { it.modifiedDate }

                toDownload.forEachIndexed { index, remote ->
                    val totalSizeMb = String.format(Locale.US, "%.1f", remote.size / (1024.0 * 1024.0))
                    localFiles[remote.name]?.let { DocumentFile.fromSingleUri(applicationContext, it.uri)?.delete() }
                    musicDir.createFile(AudioFileValidator.getMimeType(remote.name), remote.name)?.let { newFile ->
                        webDAV.downloadToFile(applicationContext, remote.name, newFile) { bytesRead ->
                            val currentMb = String.format(Locale.US, "%.1f", bytesRead / (1024.0 * 1024.0))
                            updateProgress("Downloading...", remote.name, index+1, toDownload.size, currentMb, totalSizeMb)
                        }.let { res ->
                            if (res.isSuccess) {
                                metadataReader.readMetadata(applicationContext, newFile.uri)?.let { s ->
                                    val serverVer = remoteMetadata.optLong(remote.name, System.currentTimeMillis())
                                    val existing = songDao.getAllSongsSorted().find { it.fileName == s.fileName }
                                    if (existing != null) songDao.updateSong(s.copy(id = existing.id, modifiedTime = serverVer))
                                    else songDao.insertSong(s.copy(modifiedTime = serverVer))
                                }
                            }
                        }
                    }
                }
            }

            // 3. 收藏同步：引入 LWW (Last Write Wins) 时间戳策略
            updateProgress("Syncing Favourites...", "", 0, 0, "", "")
            syncFavouritesWithLWW(webDAV)

            applicationContext.sendBroadcast(Intent(ACTION_SYNC_COMPLETED))
            Result.success()
        } catch (e: Exception) {
            Result.failure()
        }
    }

    private suspend fun syncFavouritesWithLWW(helper: WebDAVHelper) {
        val fileName = "favourites_v2.json" // 升级格式，不影响旧版
        val tempFile = File(applicationContext.cacheDir, fileName)
        
        // 1. 获取本地所有歌曲的收藏状态和时间戳
        val allSongs = songDao.getAllSongsSorted()
        val localStateMap = allSongs.associateBy({ it.fileName }, { Pair(it.isFavourite, it.favLastUpdated) }).toMutableMap()

        // 2. 下载远程收藏状态
        val remoteJson = if (helper.downloadFile(applicationContext, fileName, DocumentFile.fromFile(applicationContext.cacheDir)).isSuccess) {
            try { JSONObject(tempFile.readText()) } catch (e: Exception) { JSONObject() }
        } else {
            JSONObject()
        }

        // 3. 核心合并逻辑：比对时间戳，谁新听谁的
        val finalStateMap = mutableMapOf<String, Pair<Boolean, Long>>()
        
        // 远程有的，先合并到 final
        val keys = remoteJson.keys()
        while (keys.hasNext()) {
            val fName = keys.next()
            val obj = remoteJson.getJSONObject(fName)
            val rFav = obj.getBoolean("fav")
            val rTime = obj.getLong("time")
            
            val local = localStateMap[fName]
            if (local != null) {
                // 如果本地的操作时间更晚，取本地
                if (local.second > rTime) {
                    finalStateMap[fName] = local
                } else {
                    finalStateMap[fName] = Pair(rFav, rTime)
                }
                localStateMap.remove(fName) // 处理过了
            } else {
                finalStateMap[fName] = Pair(rFav, rTime)
            }
        }
        
        // 剩下的本地独有的（没同步过的），加入 final
        finalStateMap.putAll(localStateMap)

        // 4. 将最终结果应用到本地数据库
        allSongs.forEach { song ->
            val final = finalStateMap[song.fileName]
            if (final != null) {
                // 只有状态不一致或者本地时间戳落后时才更新
                if (song.isFavourite != final.first) {
                    songDao.updateFavouriteStatusWithTimestamp(song.id, final.first, final.second)
                }
            }
        }

        // 5. 将最终结果重新上传回服务器
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

    private suspend fun uploadRemoteMetadata(helper: WebDAVHelper, json: JSONObject) {
        val tempFile = File(applicationContext.cacheDir, METADATA_FILE)
        tempFile.writeText(json.toString())
        helper.uploadFile(applicationContext, DocumentFile.fromFile(tempFile))
    }

    private suspend fun updateProgress(status: String, fName: String, current: Int, total: Int, cSize: String, tSize: String) {
        val data = workDataOf("step_message" to status, "file_name" to fName, "current" to current, "total" to total, "current_size" to cSize, "total_size" to tSize)
        setProgress(data)
        val msg = if (fName.isNotEmpty()) "$status $fName ($cSize/$tSize MB)" else status
        try { setForeground(createForegroundInfo(msg)) } catch (e: Exception) {}
    }

    private fun listLocalFiles(context: Context, treeUri: Uri): List<FileInfo> {
        val files = mutableListOf<FileInfo>()
        val treeId = try { DocumentsContract.getTreeDocumentId(treeUri) } catch (e: Exception) { return emptyList() }
        val stack = mutableListOf(treeId)
        while (stack.isNotEmpty()) {
            val folderId = stack.removeAt(stack.size - 1)
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, folderId)
            context.contentResolver.query(childrenUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
                val idIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                while (cursor.moveToNext()) {
                    val id = cursor.getString(idIdx)
                    val name = cursor.getString(nameIdx) ?: continue
                    if (cursor.getString(mimeIdx) == DocumentsContract.Document.MIME_TYPE_DIR) stack.add(id)
                    else if (AudioFileValidator.isAudioFile(name) && !name.startsWith(".")) files.add(FileInfo(name, DocumentsContract.buildDocumentUriUsingTree(treeUri, id)))
                }
            }
        }
        return files
    }

    private data class FileInfo(val name: String, val uri: Uri)

    private fun createForegroundInfo(message: String): ForegroundInfo {
        val channelId = "sync_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(NotificationChannel(channelId, "Sync", NotificationManager.IMPORTANCE_LOW))
        }
        val notification = NotificationCompat.Builder(applicationContext, channelId).setContentTitle("Music Syncing").setContentText(message).setSmallIcon(android.R.drawable.stat_notify_sync).setOngoing(true).build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ForegroundInfo(1001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else ForegroundInfo(1001, notification)
    }
}
