package com.example.synctune.ui.sync

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.documentfile.provider.DocumentFile
import androidx.fragment.app.Fragment
import androidx.lifecycle.Observer
import androidx.lifecycle.lifecycleScope
import androidx.work.*
import com.example.synctune.R
import com.example.synctune.library.SongDao
import com.example.synctune.sync.AudioFileValidator
import com.example.synctune.sync.SyncManager
import com.example.synctune.sync.SyncWorker
import com.example.synctune.sync.WebDAVHelper
import com.google.android.material.card.MaterialCardView
import com.google.android.material.progressindicator.LinearProgressIndicator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.*

class SyncFragment : Fragment() {

    private lateinit var syncManager: SyncManager
    private var webDAVHelper: WebDAVHelper? = null
    private lateinit var songDao: SongDao

    private lateinit var tvStatus: TextView
    private lateinit var tvLocalCount: TextView
    private lateinit var tvCloudCount: TextView
    private lateinit var tvLastSync: TextView
    private lateinit var btnUpload: Button
    private lateinit var btnDownload: Button
    private lateinit var btnTwoWay: Button

    private lateinit var cardProgress: MaterialCardView
    private lateinit var tvProgressStatus: TextView
    private lateinit var tvProgressFile: TextView
    private lateinit var progressBar: LinearProgressIndicator
    private lateinit var tvProgressCount: TextView
    private lateinit var tvProgressSize: TextView

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        val view = inflater.inflate(R.layout.fragment_sync, container, false)
        syncManager = SyncManager(requireContext())
        songDao = SongDao(requireContext())

        initViews(view)
        setupHelper()
        updateStatusUi()
        observeSyncProgress()

        return view
    }

    private fun initViews(view: View) {
        tvStatus = view.findViewById(R.id.tv_connection_status)
        tvLocalCount = view.findViewById(R.id.tv_local_count)
        tvCloudCount = view.findViewById(R.id.tv_cloud_count)
        tvLastSync = view.findViewById(R.id.tv_last_sync)
        btnUpload = view.findViewById(R.id.btn_upload)
        btnDownload = view.findViewById(R.id.btn_download)
        btnTwoWay = view.findViewById(R.id.btn_two_way_sync)

        cardProgress = view.findViewById(R.id.card_progress)
        tvProgressStatus = view.findViewById(R.id.tv_progress_status)
        tvProgressFile = view.findViewById(R.id.tv_progress_file)
        progressBar = view.findViewById(R.id.progress_bar)
        tvProgressCount = view.findViewById(R.id.tv_progress_count)
        tvProgressSize = view.findViewById(R.id.tv_progress_size)

        btnUpload.setOnClickListener { performSync("UPLOAD") }
        btnDownload.setOnClickListener { performSync("DOWNLOAD") }
        btnTwoWay.setOnClickListener { performSync("TWO_WAY") }
    }

    private fun setupHelper() {
        if (syncManager.isWebDAVConfigured()) {
            webDAVHelper = WebDAVHelper(
                syncManager.getWebDAVUrl()!!,
                syncManager.getWebDAVUser()!!,
                syncManager.getWebDAVPass()!!
            )
        }
    }

    private fun updateStatusUi() {
        val isConfigured = syncManager.isWebDAVConfigured()
        tvStatus.text = if (isConfigured) getString(R.string.status_connected) else getString(R.string.status_disconnected)
        tvStatus.setTextColor(if (isConfigured) 0xFF4CAF50.toInt() else 0xFFF44336.toInt())

        val lastSync = syncManager.getLastSyncTime()
        if (lastSync > 0) {
            val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault())
            tvLastSync.text = getString(R.string.last_sync) + ": " + sdf.format(Date(lastSync))
        } else {
            tvLastSync.text = getString(R.string.never_synced)
        }

        lifecycleScope.launch(Dispatchers.IO) {
            val localSongs = songDao.getAllSongsSorted()
            withContext(Dispatchers.Main) {
                tvLocalCount.text = localSongs.size.toString()
            }
            val remoteFilesResult = webDAVHelper?.listRemoteFiles()
            withContext(Dispatchers.Main) {
                tvCloudCount.text = if (remoteFilesResult?.isSuccess == true) {
                    remoteFilesResult.getOrNull()?.size.toString()
                } else "0"
            }
        }
    }

    private fun observeSyncProgress() {
        WorkManager.getInstance(requireContext())
            .getWorkInfosForUniqueWorkLiveData("music_sync")
            .observe(viewLifecycleOwner, Observer { workInfos ->
                if (workInfos.isNullOrEmpty()) return@Observer
                
                val workInfo = workInfos[0]
                when (workInfo.state) {
                    WorkInfo.State.RUNNING -> {
                        setLoading(true)
                        val progress = workInfo.progress

                        val status = progress.getString("step_message") ?: "Syncing..."
                        val fileName = progress.getString("file_name") ?: ""
                        val current = progress.getInt("current", 0)
                        val total = progress.getInt("total", 0)
                        val currentSize = progress.getString("current_size") ?: "0"
                        val totalSize = progress.getString("total_size") ?: "0"
                        
                        tvProgressStatus.text = status
                        tvProgressFile.text = fileName
                        
                        if (total > 0) {
                            tvProgressCount.text = "$current / $total"
                            progressBar.isIndeterminate = false
                            progressBar.max = total
                            progressBar.progress = current
                            
                            // 这里是关键：显示 当前MB / 总共MB
                            if (totalSize != "0") {
                                tvProgressSize.text = "$currentSize / $totalSize MB"
                            } else {
                                tvProgressSize.text = ""
                            }
                        } else {
                            tvProgressCount.text = ""
                            tvProgressSize.text = ""
                            progressBar.isIndeterminate = true
                        }
                    }
                    WorkInfo.State.SUCCEEDED -> {
                        setLoading(false)
                        updateStatusUi()
                        Toast.makeText(requireContext(), R.string.sync_complete, Toast.LENGTH_SHORT).show()
                    }
                    WorkInfo.State.FAILED -> {
                        setLoading(false)
                        Toast.makeText(requireContext(), R.string.sync_failed, Toast.LENGTH_SHORT).show()
                    }
                    else -> setLoading(false)
                }
            })
    }

    private fun performSync(type: String) {
        if (!syncManager.isWebDAVConfigured()) {
            Toast.makeText(requireContext(), R.string.status_disconnected, Toast.LENGTH_SHORT).show()
            return
        }

        val data = Data.Builder().putString("sync_type", type).build()
        val constraints = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
        val syncRequest = OneTimeWorkRequestBuilder<SyncWorker>()
            .setInputData(data)
            .setConstraints(constraints)
            .addTag("music_sync")
            .build()

        WorkManager.getInstance(requireContext())
            .enqueueUniqueWork("music_sync", ExistingWorkPolicy.REPLACE, syncRequest)
    }

    private fun setLoading(loading: Boolean) {
        cardProgress.visibility = if (loading) View.VISIBLE else View.GONE
        btnUpload.isEnabled = !loading
        btnDownload.isEnabled = !loading
        btnTwoWay.isEnabled = !loading
    }

    private fun getLocalAudioFiles(): List<DocumentFile> {
        val prefs = requireActivity().getSharedPreferences("SyncTunePrefs", Context.MODE_PRIVATE)
        val savedUriString = prefs.getString("music_directory_uri", null) ?: return emptyList()
        val rootDoc = DocumentFile.fromTreeUri(requireContext(), Uri.parse(savedUriString)) ?: return emptyList()
        val result = mutableListOf<DocumentFile>()
        fun scan(dir: DocumentFile) {
            dir.listFiles().forEach { file -> if (file.isDirectory) scan(file) else if (AudioFileValidator.isAudioFile(file.name)) result.add(file) }
        }
        scan(rootDoc)
        return result
    }
}
