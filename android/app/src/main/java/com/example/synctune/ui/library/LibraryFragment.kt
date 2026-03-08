package com.example.synctune.ui.library

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.widget.PopupMenu
import androidx.documentfile.provider.DocumentFile
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.synctune.R
import com.example.synctune.library.MetadataReader
import com.example.synctune.library.Song
import com.example.synctune.library.SongDao
import com.example.synctune.player.PlayerManager
import com.example.synctune.sync.AudioFileValidator
import com.example.synctune.sync.SyncManager
import com.example.synctune.sync.WebDAVHelper
import com.google.android.material.card.MaterialCardView
import com.google.android.material.tabs.TabLayout
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

class LibraryFragment : Fragment() {

    private lateinit var songDao: SongDao
    private lateinit var songAdapter: SongAdapter
    private lateinit var syncManager: SyncManager
    private val metadataReader = MetadataReader()
    private var currentTab = 0 // 0: All, 1: Favourites
    private var favCache = mutableMapOf<String, Boolean>()
    
    private enum class SortOrder { NAME, ARTIST, DATE }
    // 修改默认排序为日期排序
    private var currentSortOrder = SortOrder.DATE
    private var searchQuery: String = ""

    private var backPressedCallback: OnBackPressedCallback? = null

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        val view = inflater.inflate(R.layout.fragment_library, container, false)
        
        songDao = SongDao(requireContext())
        syncManager = SyncManager(requireContext())

        val recyclerView = view.findViewById<RecyclerView>(R.id.recycler_view_songs)
        val cardScan = view.findViewById<MaterialCardView>(R.id.card_scan)
        val tvSelectionCount = view.findViewById<TextView>(R.id.tv_selection_count)
        val btnDeleteSelected = view.findViewById<ImageButton>(R.id.btn_delete_selected)
        val btnCancelSelection = view.findViewById<ImageButton>(R.id.btn_cancel_selection)
        val btnSort = view.findViewById<ImageButton>(R.id.btn_sort)
        val btnSearch = view.findViewById<ImageButton>(R.id.btn_search)
        val tabLayout = view.findViewById<TabLayout>(R.id.tab_layout_library)
        val tilSearch = view.findViewById<TextInputLayout>(R.id.til_search)
        val etSearch = view.findViewById<TextInputEditText>(R.id.et_search)

        // 初始化返回键监听
        backPressedCallback = object : OnBackPressedCallback(false) {
            override fun handleOnBackPressed() {
                if (songAdapter.isSelectionModeEnabled()) {
                    songAdapter.setSelectionMode(false)
                }
            }
        }
        requireActivity().onBackPressedDispatcher.addCallback(viewLifecycleOwner, backPressedCallback!!)

        songAdapter = SongAdapter(emptyList(), { song ->
            val allSongs = songAdapter.getSongs()
            val startIndex = allSongs.indexOf(song)
            PlayerManager.play(requireContext(), allSongs, startIndex)
        }, { song ->
            showDeleteSongDialog(song)
        }, { song ->
            toggleFavourite(song)
        }, { count ->
            val isSelectionMode = count > 0 || songAdapter.isSelectionModeEnabled()
            backPressedCallback?.isEnabled = isSelectionMode
            
            if (isSelectionMode) {
                tvSelectionCount.visibility = View.GONE 
                btnDeleteSelected.visibility = View.VISIBLE
                btnCancelSelection.visibility = View.VISIBLE
                btnSearch.visibility = View.GONE
                btnSort.visibility = View.GONE
            } else {
                tvSelectionCount.visibility = View.GONE
                btnDeleteSelected.visibility = View.GONE
                btnCancelSelection.visibility = View.GONE
                btnSearch.visibility = View.VISIBLE
                btnSort.visibility = View.VISIBLE
            }
        })

        recyclerView.layoutManager = LinearLayoutManager(requireContext())
        recyclerView.adapter = songAdapter

        tabLayout.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab?) {
                currentTab = tab?.position ?: 0
                loadSongs()
            }
            override fun onTabUnselected(tab: TabLayout.Tab?) {}
            override fun onTabReselected(tab: TabLayout.Tab?) {}
        })

        btnCancelSelection.setOnClickListener {
            songAdapter.setSelectionMode(false)
        }

        btnDeleteSelected.setOnClickListener {
            val selectedSongs = songAdapter.getSelectedSongs()
            if (selectedSongs.isNotEmpty()) {
                showDeleteMultipleSongsDialog(selectedSongs)
            }
        }

        btnSort.setOnClickListener {
            showSortMenu(it)
        }

        btnSearch.setOnClickListener {
            if (tilSearch.visibility == View.GONE) {
                tilSearch.visibility = View.VISIBLE
                etSearch.requestFocus()
            } else {
                tilSearch.visibility = View.GONE
                etSearch.text?.clear()
                searchQuery = ""
                loadSongs()
            }
        }

        etSearch.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                searchQuery = s?.toString() ?: ""
                loadSongs()
            }
            override fun afterTextChanged(s: Editable?) {}
        })

        setupPlayerListener()
        loadSongs()

        cardScan.setOnClickListener {
            scanMusic()
        }

        return view
    }

    private fun showSortMenu(view: View) {
        val popup = PopupMenu(requireContext(), view)
        popup.menu.add(0, 0, 0, "Sort by Name")
        popup.menu.add(0, 1, 1, "Sort by Artist")
        popup.menu.add(0, 2, 2, "Sort by Date")
        
        popup.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                0 -> currentSortOrder = SortOrder.NAME
                1 -> currentSortOrder = SortOrder.ARTIST
                2 -> currentSortOrder = SortOrder.DATE
            }
            loadSongs()
            true
        }
        popup.show()
    }

    private fun toggleFavourite(song: Song) {
        lifecycleScope.launch(Dispatchers.IO) {
            val newStatus = !song.isFavourite
            songDao.updateFavouriteStatus(song.id, newStatus)
            
            try {
                val url = syncManager.getWebDAVUrl()
                val user = syncManager.getWebDAVUser()
                val pass = syncManager.getWebDAVPass()
                if (!url.isNullOrEmpty() && !user.isNullOrEmpty() && !pass.isNullOrEmpty()) {
                    val helper = WebDAVHelper(url, user, pass)
                    uploadFavouritesJson(helper)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }

            withContext(Dispatchers.Main) {
                loadSongs()
            }
        }
    }

    private suspend fun uploadFavouritesJson(helper: WebDAVHelper) {
        val allSongs = songDao.getAllSongs()
        val favJson = JSONObject()
        allSongs.forEach { song ->
            if (song.fileHash.isNotEmpty()) {
                favJson.put(song.fileHash, song.isFavourite)
            }
        }
        val tempFile = File(requireContext().cacheDir, "favourites.json")
        tempFile.writeText(favJson.toString())
        helper.uploadFile(requireContext(), DocumentFile.fromFile(tempFile))
    }

    private fun showDeleteMultipleSongsDialog(songs: List<Song>) {
        AlertDialog.Builder(requireContext())
            .setTitle("Delete Songs")
            .setMessage("Are you sure you want to delete ${songs.size} selected songs?")
            .setPositiveButton("Local Only") { _, _ ->
                deleteSongs(songs, deleteRemote = false)
            }
            .setNeutralButton("Local & Cloud") { _, _ ->
                deleteSongs(songs, deleteRemote = true)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun deleteSongs(songs: List<Song>, deleteRemote: Boolean) {
        lifecycleScope.launch(Dispatchers.IO) {
            val url = syncManager.getWebDAVUrl() ?: ""
            val user = syncManager.getWebDAVUser() ?: ""
            val pass = syncManager.getWebDAVPass() ?: ""
            
            val webDAVHelper = if (deleteRemote && url.isNotEmpty()) {
                WebDAVHelper(url, user, pass)
            } else null

            songs.forEach { song ->
                val fileName = song.fileName.takeIf { it.isNotEmpty() } ?: try {
                    val uri = Uri.parse(song.filePath)
                    val doc = DocumentFile.fromSingleUri(requireContext(), uri)
                    doc?.name ?: ""
                } catch (e: Exception) { "" }

                if (webDAVHelper != null && fileName.isNotEmpty()) {
                    try {
                        webDAVHelper.deleteFile(fileName)
                    } catch (e: Exception) { e.printStackTrace() }
                }

                try {
                    val uri = Uri.parse(song.filePath)
                    DocumentFile.fromSingleUri(requireContext(), uri)?.delete()
                } catch (e: Exception) { e.printStackTrace() }

                songDao.deleteSongById(song.id)
            }

            withContext(Dispatchers.Main) {
                songAdapter.setSelectionMode(false)
                loadSongs()
                Toast.makeText(requireContext(), "Deletion completed", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun showDeleteSongDialog(song: Song) {
        AlertDialog.Builder(requireContext())
            .setTitle("Delete Song")
            .setMessage("Are you sure you want to delete \"${song.title}\"?")
            .setPositiveButton("Local Only") { _, _ ->
                deleteSong(song, deleteRemote = false)
            }
            .setNeutralButton("Local & Cloud") { _, _ ->
                deleteSong(song, deleteRemote = true)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun deleteSong(song: Song, deleteRemote: Boolean) {
        deleteSongs(listOf(song), deleteRemote)
    }

    private fun setupPlayerListener() {
        val player = PlayerManager.getPlayer(requireContext())
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                val currentPath = mediaItem?.localConfiguration?.uri?.toString()
                songAdapter.setPlayingSongPath(currentPath)
            }
        })
        songAdapter.setPlayingSongPath(player.currentMediaItem?.localConfiguration?.uri?.toString())
    }

    private fun loadSongs() {
        lifecycleScope.launch(Dispatchers.IO) {
            var songs = if (currentTab == 0) songDao.getAllSongs() else songDao.getFavouriteSongs()
            
            if (searchQuery.isNotEmpty()) {
                songs = songs.filter { 
                    it.title.contains(searchQuery, ignoreCase = true) || 
                    it.artist.contains(searchQuery, ignoreCase = true) ||
                    it.album.contains(searchQuery, ignoreCase = true)
                }
            }

            songs = when (currentSortOrder) {
                SortOrder.NAME -> songs.sortedBy { it.title.lowercase() }
                SortOrder.ARTIST -> songs.sortedBy { it.artist.lowercase() }
                SortOrder.DATE -> songs.sortedByDescending { it.modifiedTime }
            }

            withContext(Dispatchers.Main) {
                songAdapter.updateSongs(songs)
                val currentPath = PlayerManager.getPlayer(requireContext()).currentMediaItem?.localConfiguration?.uri?.toString()
                songAdapter.setPlayingSongPath(currentPath)
            }
        }
    }

    private fun scanMusic() {
        val prefs = requireActivity().getSharedPreferences("SyncTunePrefs", Context.MODE_PRIVATE)
        val savedUriString = prefs.getString("music_directory_uri", null)

        if (savedUriString == null) {
            Toast.makeText(requireContext(), R.string.local_library_desc, Toast.LENGTH_LONG).show()
            return
        }

        Toast.makeText(requireContext(), R.string.status_scanning, Toast.LENGTH_SHORT).show()
        
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                val url = syncManager.getWebDAVUrl()
                val user = syncManager.getWebDAVUser()
                val pass = syncManager.getWebDAVPass()
                if (!url.isNullOrEmpty() && !user.isNullOrEmpty() && !pass.isNullOrEmpty()) {
                    val helper = WebDAVHelper(url, user, pass)
                    loadFavCache(helper)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }

            val rootUri = Uri.parse(savedUriString)
            val rootDoc = DocumentFile.fromTreeUri(requireContext(), rootUri)

            if (rootDoc == null || !rootDoc.canRead()) {
                withContext(Dispatchers.Main) {
                    Toast.makeText(requireContext(), R.string.error_dir_not_writable, Toast.LENGTH_SHORT).show()
                }
                return@launch
            }

            val foundUris = mutableSetOf<String>()
            scanDirectory(rootDoc, foundUris)

            val allDbSongs = songDao.getAllSongs()
            allDbSongs.forEach { song ->
                val remoteIsFav = favCache[song.fileHash] ?: false
                if (remoteIsFav && !song.isFavourite) {
                    songDao.updateFavouriteStatus(song.id, true)
                }
            }

            val deletedSongs = allDbSongs.filter { !foundUris.contains(it.filePath) }
            
            withContext(Dispatchers.Main) {
                if (deletedSongs.isNotEmpty()) {
                    showDeleteConfirmation(deletedSongs)
                } else {
                    refreshLibrary()
                }
            }
        }
    }

    private suspend fun loadFavCache(helper: WebDAVHelper) {
        try {
            val tempFile = File(requireContext().cacheDir, "favourites.json")
            val remoteFilesResult = helper.listAllResources()
            if (remoteFilesResult.isSuccess) {
                val remoteFiles = remoteFilesResult.getOrNull() ?: emptyList()
                val hasRemote = remoteFiles.any { it.name == "favourites.json" }
                
                if (hasRemote) {
                    val downloadResult = helper.downloadFile(requireContext(), "favourites.json", DocumentFile.fromFile(requireContext().cacheDir))
                    if (downloadResult.isSuccess && tempFile.exists()) {
                        val json = JSONObject(tempFile.readText())
                        val keys = json.keys()
                        while (keys.hasNext()) {
                            val hash = keys.next()
                            favCache[hash] = json.optBoolean(hash, false)
                        }
                    }
                }
            }
        } catch (e: Exception) { e.printStackTrace() }
    }

    private fun showDeleteConfirmation(deletedSongs: List<Song>) {
        AlertDialog.Builder(requireContext())
            .setTitle(R.string.delete_linkage_title)
            .setMessage(getString(R.string.delete_linkage_desc, if (deletedSongs.size > 1) "these songs" else deletedSongs[0].title))
            .setPositiveButton(R.string.btn_delete_cloud) { _, _ ->
                lifecycleScope.launch(Dispatchers.IO) {
                    deletedSongs.forEach { songDao.deleteSongById(it.id) }
                    refreshLibrary()
                }
            }
            .setNegativeButton(R.string.btn_keep_cloud) { _, _ ->
                lifecycleScope.launch(Dispatchers.IO) {
                    deletedSongs.forEach { songDao.deleteSongById(it.id) }
                    refreshLibrary()
                }
            }
            .show()
    }

    private fun refreshLibrary() {
        lifecycleScope.launch(Dispatchers.IO) {
            val songs = if (currentTab == 0) songDao.getAllSongs() else songDao.getFavouriteSongs()
            withContext(Dispatchers.Main) {
                songAdapter.updateSongs(songs)
                Toast.makeText(requireContext(), R.string.scan_complete, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun scanDirectory(directory: DocumentFile, foundUris: MutableSet<String>) {
        directory.listFiles().forEach { file ->
            if (file.isDirectory) {
                scanDirectory(file, foundUris)
            } else if (AudioFileValidator.isAudioFile(file.name)) {
                val uriString = file.uri.toString()
                foundUris.add(uriString)
                
                if (!songDao.isSongExistsByPath(uriString)) {
                    val song = metadataReader.readMetadata(requireContext(), file.uri)
                    if (song != null) {
                        if (songDao.isSongExists(song.fileHash)) {
                            songDao.updateFileNameAndPath(song.fileHash, song.fileName, uriString)
                        } else {
                            val isFav = favCache[song.fileHash] ?: false
                            val songWithFav = song.copy(isFavourite = isFav)
                            songDao.insertSong(songWithFav)
                        }
                    }
                }
            }
        }
    }
}
