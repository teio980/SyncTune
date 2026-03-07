package com.example.synctune.ui.settings

import android.app.Activity
import android.content.Context
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
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import com.example.synctune.R
import com.example.synctune.sync.SyncManager
import com.example.synctune.sync.WebDAVHelper
import com.google.android.material.card.MaterialCardView
import com.google.android.material.switchmaterial.SwitchMaterial
import com.google.android.material.textfield.TextInputEditText
import kotlinx.coroutines.launch

class SettingsFragment : Fragment() {

    private lateinit var syncManager: SyncManager
    private lateinit var etUrl: TextInputEditText
    private lateinit var etUser: TextInputEditText
    private lateinit var etPass: TextInputEditText
    private lateinit var btnSave: Button
    private lateinit var btnTest: Button
    private lateinit var btnDisconnect: Button
    private lateinit var switchAutoSync: SwitchMaterial
    private lateinit var tvCurrentPath: TextView
    private lateinit var cardPath: MaterialCardView

    private val selectDirectoryLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val directoryUri: Uri? = result.data?.data
            directoryUri?.let { uri ->
                requireContext().contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                
                val prefs = requireActivity().getSharedPreferences("SyncTunePrefs", Context.MODE_PRIVATE)
                prefs.edit().putString("music_directory_uri", uri.toString()).apply()
                
                updatePathDisplay(uri.toString())
                Toast.makeText(requireContext(), "目录已更新", Toast.LENGTH_SHORT).show()
            }
        }
    }

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        val view = inflater.inflate(R.layout.fragment_settings, container, false)
        syncManager = SyncManager(requireContext())

        initViews(view)
        setupListeners()
        loadConfig()

        return view
    }

    private fun initViews(view: View) {
        etUrl = view.findViewById(R.id.et_webdav_url)
        etUser = view.findViewById(R.id.et_webdav_user)
        etPass = view.findViewById(R.id.et_webdav_pass)
        btnSave = view.findViewById(R.id.btn_save_config)
        btnTest = view.findViewById(R.id.btn_test_connection)
        btnDisconnect = view.findViewById(R.id.btn_disconnect)
        switchAutoSync = view.findViewById(R.id.switch_auto_sync)
        tvCurrentPath = view.findViewById(R.id.tv_current_path)
        cardPath = view.findViewById(R.id.card_path)
    }

    private fun setupListeners() {
        btnTest.setOnClickListener {
            val url = etUrl.text.toString()
            val user = etUser.text.toString()
            val pass = etPass.text.toString()

            if (url.isBlank() || user.isBlank() || pass.isBlank()) {
                Toast.makeText(requireContext(), R.string.invalid_config, Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }

            lifecycleScope.launch {
                btnTest.isEnabled = false
                val helper = WebDAVHelper(url, user, pass)
                val result = helper.testConnection()
                btnTest.isEnabled = true

                if (result.isSuccess) {
                    Toast.makeText(requireContext(), R.string.connection_success, Toast.LENGTH_SHORT).show()
                    btnSave.isEnabled = true
                } else {
                    val error = result.exceptionOrNull()?.message ?: "Unknown error"
                    Toast.makeText(requireContext(), getString(R.string.connection_failed, error), Toast.LENGTH_LONG).show()
                }
            }
        }

        btnSave.setOnClickListener {
            val url = etUrl.text.toString()
            val user = etUser.text.toString()
            val pass = etPass.text.toString()
            syncManager.saveWebDAVConfig(url, user, pass)
            Toast.makeText(requireContext(), R.string.sync_complete, Toast.LENGTH_SHORT).show()
            updateUiState(true)
        }

        btnDisconnect.setOnClickListener {
            syncManager.disconnectWebDAV()
            etUrl.setText("")
            etUser.setText("")
            etPass.setText("")
            updateUiState(false)
        }

        switchAutoSync.setOnCheckedChangeListener { _, isChecked ->
            syncManager.setAutoSyncEnabled(isChecked)
        }

        cardPath.setOnClickListener {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            selectDirectoryLauncher.launch(intent)
        }
    }

    private fun loadConfig() {
        val isConfigured = syncManager.isWebDAVConfigured()
        if (isConfigured) {
            etUrl.setText(syncManager.getWebDAVUrl())
            etUser.setText(syncManager.getWebDAVUser())
            etPass.setText(syncManager.getWebDAVPass())
        }
        updateUiState(isConfigured)

        switchAutoSync.isChecked = syncManager.isAutoSyncEnabled()

        val prefs = requireActivity().getSharedPreferences("SyncTunePrefs", Context.MODE_PRIVATE)
        val savedUriString = prefs.getString("music_directory_uri", null)
        updatePathDisplay(savedUriString)
    }

    private fun updatePathDisplay(uriString: String?) {
        if (uriString != null) {
            val path = Uri.parse(uriString).path?.substringAfterLast(':') ?: getString(R.string.path_not_set)
            tvCurrentPath.text = getString(R.string.path_set, path)
        } else {
            tvCurrentPath.text = getString(R.string.path_not_set)
        }
    }

    private fun updateUiState(isConfigured: Boolean) {
        btnDisconnect.visibility = if (isConfigured) View.VISIBLE else View.GONE
        btnSave.isEnabled = false // Only enable after successful test
        if (isConfigured) {
            btnSave.text = getString(R.string.btn_save_config)
        }
    }
}
