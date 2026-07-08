package com.example.synctune.ui.sync

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.documentfile.provider.DocumentFile
import androidx.fragment.app.Fragment
import androidx.lifecycle.Observer
import androidx.lifecycle.lifecycleScope
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.example.synctune.R
import com.example.synctune.library.SongDao
import com.example.synctune.sync.SyncManager
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
    private lateinit var btnSyncNow: Button
    private lateinit var btnUploadFile: Button
    private lateinit var btnDeleteCloudSongs: Button

    private lateinit var cardProgress: MaterialCardView
    private lateinit var tvProgressStatus: TextView
    private lateinit var tvProgressFile: TextView
    private lateinit var progressBar: LinearProgressIndicator
    private lateinit var tvProgressCount: TextView
    private lateinit var tvProgressSize: TextView

    private val pickAudioLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val uri: Uri? = result.data?.data
            uri?.let { uploadSelectedFile(it) }
        }
    }

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
        btnSyncNow = view.findViewById(R.id.btn_sync_now)
        btnUploadFile = view.findViewById(R.id.btn_upload_file)
        btnDeleteCloudSongs = view.findViewById(R.id.btn_delete_cloud_songs)

        cardProgress = view.findViewById(R.id.card_progress)
        tvProgressStatus = view.findViewById(R.id.tv_progress_status)
        tvProgressFile = view.findViewById(R.id.tv_progress_file)
        progressBar = view.findViewById(R.id.progress_bar)
        tvProgressCount = view.findViewById(R.id.tv_progress_count)
        tvProgressSize = view.findViewById(R.id.tv_progress_size)

        btnSyncNow.setOnClickListener { performSync() }
        btnUploadFile.setOnClickListener {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "audio/*"
            }
            pickAudioLauncher.launch(intent)
        }
        btnDeleteCloudSongs.setOnClickListener { showCloudSongsDeleteDialog() }
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
            .getWorkInfosForUniqueWorkLiveData(SyncManager.UNIQUE_SYNC_WORK_NAME)
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

    private fun performSync() {
        if (!syncManager.isWebDAVConfigured()) {
            Toast.makeText(requireContext(), R.string.status_disconnected, Toast.LENGTH_SHORT).show()
            return
        }

        syncManager.startSyncNow()
    }

    private fun uploadSelectedFile(uri: Uri) {
        val documentFile = DocumentFile.fromSingleUri(requireContext(), uri) ?: return
        if (webDAVHelper == null) {
            Toast.makeText(requireContext(), R.string.status_disconnected, Toast.LENGTH_SHORT).show()
            return
        }

        val totalSize = documentFile.length()
        val totalSizeMb = String.format(Locale.US, "%.1f", totalSize / (1024.0 * 1024.0))

        setLoading(true)
        tvProgressStatus.text = getString(R.string.uploading)
        tvProgressFile.text = documentFile.name
        tvProgressCount.text = "1 / 1"
        progressBar.isIndeterminate = false
        progressBar.max = 100
        progressBar.progress = 0
        
        lifecycleScope.launch {
            val result = webDAVHelper?.uploadFile(requireContext(), documentFile) { bytesWritten ->
                withContext(Dispatchers.Main) {
                    val currentMb = String.format(Locale.US, "%.1f", bytesWritten / (1024.0 * 1024.0))
                    tvProgressSize.text = "$currentMb / $totalSizeMb MB"
                    if (totalSize > 0) {
                        progressBar.progress = ((bytesWritten * 100) / totalSize).toInt()
                    }
                }
            }
            setLoading(false)
            if (result?.isSuccess == true) {
                Toast.makeText(requireContext(), "Upload Successful", Toast.LENGTH_SHORT).show()
                updateStatusUi()
            } else {
                val error = result?.exceptionOrNull()?.message ?: "Unknown error"
                Toast.makeText(requireContext(), "Upload Failed: $error", Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun showCloudSongsDeleteDialog() {
        if (webDAVHelper == null) {
            Toast.makeText(requireContext(), R.string.status_disconnected, Toast.LENGTH_SHORT).show()
            return
        }

        setLoading(true)
        lifecycleScope.launch {
            val result = webDAVHelper?.listRemoteFiles()
            setLoading(false)
            if (result?.isSuccess == true) {
                val files = result.getOrThrow()
                    .sortedByDescending { it.modifiedDate } // 按修改时间从新到旧排序

                if (files.isEmpty()) {
                    Toast.makeText(requireContext(), R.string.no_cloud_songs, Toast.LENGTH_SHORT).show()
                    return@launch
                }

                val fileNames = files.map { it.name }.toTypedArray()
                val selectedItems = BooleanArray(fileNames.size) { false }
                
                AlertDialog.Builder(requireContext(), R.style.Theme_SyncTune_AlertDialog)
                    .setTitle(R.string.delete_cloud_title)
                    .setMultiChoiceItems(fileNames, selectedItems) { _, which, isChecked ->
                        selectedItems[which] = isChecked
                    }
                    .setPositiveButton(R.string.delete_confirm) { _, _ ->
                        val toDelete = files.filterIndexed { index, _ -> selectedItems[index] }
                        if (toDelete.isNotEmpty()) deleteCloudSongs(toDelete.map { it.name })
                    }
                    .setNegativeButton(R.string.cancel, null)
                    .show()
            } else {
                Toast.makeText(requireContext(), "Failed to fetch cloud songs", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun deleteCloudSongs(fileNames: List<String>) {
        setLoading(true)
        tvProgressStatus.text = getString(R.string.deleting_songs)
        progressBar.isIndeterminate = false
        progressBar.max = fileNames.size
        progressBar.progress = 0
        tvProgressCount.text = "0 / ${fileNames.size}"
        tvProgressSize.text = ""

        lifecycleScope.launch {
            var successCount = 0
            fileNames.forEachIndexed { index, fileName ->
                tvProgressFile.text = fileName
                val result = webDAVHelper?.deleteFile(fileName)
                if (result?.isSuccess == true) successCount++
                progressBar.progress = index + 1
                tvProgressCount.text = "${index + 1} / ${fileNames.size}"
            }
            setLoading(false)
            Toast.makeText(requireContext(), "Deleted $successCount songs", Toast.LENGTH_SHORT).show()
            updateStatusUi()
        }
    }

    private fun setLoading(loading: Boolean) {
        cardProgress.visibility = if (loading) View.VISIBLE else View.GONE
        btnSyncNow.isEnabled = !loading
        btnUploadFile.isEnabled = !loading
        btnDeleteCloudSongs.isEnabled = !loading
    }
}
