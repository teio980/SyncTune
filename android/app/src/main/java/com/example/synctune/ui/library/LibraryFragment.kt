package com.example.synctune.ui.library

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.text.*
import android.view.*
import android.widget.*
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.widget.PopupMenu
import androidx.documentfile.provider.DocumentFile
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.recyclerview.widget.*
import com.example.synctune.R
import com.example.synctune.library.*
import com.example.synctune.player.PlaybackService
import com.example.synctune.player.PlayerManager
import com.example.synctune.sync.*
import com.google.android.material.card.MaterialCardView
import com.google.android.material.progressindicator.LinearProgressIndicator
import com.google.android.material.tabs.TabLayout
import com.google.android.material.textfield.*
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors
import kotlinx.coroutines.*

class LibraryFragment : Fragment() {
    private lateinit var songDao: SongDao
    private lateinit var songAdapter: SongAdapter
    private lateinit var syncManager: SyncManager
    private val metadataReader = MetadataReader()
    private var currentTab = 0
    private var currentSortOrder = 2
    private var searchQuery = ""
    private var scanProgressBar: LinearProgressIndicator? = null
    private var songToEdit: Song? = null
    private var controllerFuture: ListenableFuture<MediaController>? = null
    private var mediaController: MediaController? = null
    private var observedPlayer: Player? = null
    private var menuBarsAutoHideController: LibraryMenuBarsAutoHideController? = null
    private val playerListener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            syncCurrentPlayingPath()
        }
    }

    private val syncReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == SyncWorker.ACTION_SYNC_COMPLETED) {
                lifecycleScope.launch(Dispatchers.Main) {
                    refresh()
                }
            }
        }
    }

    private val pickImageLauncher = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) songToEdit?.let { updateSongCover(it, uri) }
    }

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View? {
        val v = inflater.inflate(R.layout.fragment_library, container, false)
        songDao = SongDao(requireContext()); syncManager = SyncManager(requireContext())
        scanProgressBar = v.findViewById(R.id.scan_progress)
        songAdapter = SongAdapter(emptyList(), { s -> playSongFromSearch(s) },
            { s -> showSongOptions(s) }, { s -> toggleFav(s) }, { c -> updateUI(v, c) })
        v.findViewById<RecyclerView>(R.id.recycler_view_songs).apply { 
            layoutManager = LinearLayoutManager(context)
            adapter = songAdapter
            setupSwipeHandler(this) 
        }
        v.findViewById<TabLayout>(R.id.tab_layout_library).addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(t: TabLayout.Tab?) { currentTab = t?.position ?: 0; refresh() }
            override fun onTabUnselected(t: TabLayout.Tab?) {}; override fun onTabReselected(t: TabLayout.Tab?) {}
        })
        v.findViewById<MaterialCardView>(R.id.card_scan).setOnClickListener { scan() }
        setupSearch(v); refresh()
        registerSearchBackHandler(v)
        menuBarsAutoHideController = LibraryMenuBarsAutoHideController(
            v,
            requireActivity().findViewById(R.id.bottom_navigation),
            requireActivity().findViewById(R.id.mini_player_card),
        ).also { it.attach() }
        
        setupPlayerListener()
        syncCurrentPlayingPath()
        
        return v
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter(SyncWorker.ACTION_SYNC_COMPLETED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requireContext().registerReceiver(syncReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            requireContext().registerReceiver(syncReceiver, filter)
        }

        val sessionToken = SessionToken(requireContext(), ComponentName(requireContext(), PlaybackService::class.java))
        controllerFuture = MediaController.Builder(requireContext(), sessionToken).buildAsync()
        controllerFuture?.addListener({
            try {
                mediaController = controllerFuture?.get()
                setupPlayerListener()
                syncCurrentPlayingPath()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }, MoreExecutors.directExecutor())
    }

    override fun onStop() {
        super.onStop()
        observedPlayer?.removeListener(playerListener)
        observedPlayer = null
        controllerFuture?.let { MediaController.releaseFuture(it) }
        controllerFuture = null
        mediaController = null
        requireContext().unregisterReceiver(syncReceiver)
    }

    override fun onDestroyView() {
        menuBarsAutoHideController?.detach()
        menuBarsAutoHideController = null
        observedPlayer?.removeListener(playerListener)
        observedPlayer = null
        super.onDestroyView()
    }
    
    private fun syncCurrentPlayingPath() {
        val player = activePlayer() ?: return
        val currentUri = player.currentMediaItem?.localConfiguration?.uri?.toString()
        songAdapter.setPlayingSongPath(currentUri)
    }

    private fun updateUI(v: View, c: Int) {
        val m = c > 0 || songAdapter.isSelectionModeEnabled()
        v.findViewById<View>(R.id.btn_delete_selected).visibility = if (m) View.VISIBLE else View.GONE
        v.findViewById<View>(R.id.btn_edit_selected).visibility = if (m && c == 1) View.VISIBLE else View.GONE
        v.findViewById<View>(R.id.btn_cancel_selection).visibility = if (m) View.VISIBLE else View.GONE
        v.findViewById<View>(R.id.btn_search).visibility = if (m) View.GONE else View.VISIBLE
        v.findViewById<View>(R.id.btn_sort).visibility = if (m) View.GONE else View.VISIBLE
    }

    private fun setupSearch(v: View) {
        val til = v.findViewById<TextInputLayout>(R.id.til_search); val et = v.findViewById<TextInputEditText>(R.id.et_search)
        v.findViewById<View>(R.id.btn_search).setOnClickListener { if (til.visibility == View.GONE) { til.visibility = View.VISIBLE; et.requestFocus() } else { closeSearch(v) } }
        et.addTextChangedListener(object : TextWatcher {
            override fun onTextChanged(s: CharSequence?, st: Int, b: Int, c: Int) { searchQuery = s?.toString() ?: ""; refresh() }
            override fun beforeTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}; override fun afterTextChanged(p0: Editable?) {}
        })
        v.findViewById<View>(R.id.btn_sort).setOnClickListener { val p = PopupMenu(requireContext(), it); p.menu.add(0,0,0,"Name"); p.menu.add(0,1,1,"Artist"); p.menu.add(0,2,2,"Date"); p.setOnMenuItemClickListener { i -> currentSortOrder = i.itemId; refresh(); true }; p.show() }
        v.findViewById<View>(R.id.btn_cancel_selection).setOnClickListener { songAdapter.setSelectionMode(false) }
        v.findViewById<View>(R.id.btn_delete_selected).setOnClickListener { val s = songAdapter.getSelectedSongs(); if (s.isNotEmpty()) deleteSongs(s) }
        v.findViewById<View>(R.id.btn_edit_selected).setOnClickListener { val s = songAdapter.getSelectedSongs(); if (s.size == 1) startCoverEdit(s[0]) }
    }

    private fun registerSearchBackHandler(v: View) {
        requireActivity().onBackPressedDispatcher.addCallback(viewLifecycleOwner, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (v.findViewById<TextInputLayout>(R.id.til_search).visibility == View.VISIBLE) {
                    closeSearch(v)
                } else {
                    isEnabled = false
                    requireActivity().onBackPressedDispatcher.onBackPressed()
                }
            }
        })
    }

    private fun closeSearch(v: View) {
        v.findViewById<TextInputLayout>(R.id.til_search).visibility = View.GONE
        v.findViewById<TextInputEditText>(R.id.et_search).text?.clear()
        searchQuery = ""
        refresh()
    }

    private fun showSongOptions(s: Song) { val opts = arrayOf("Edit Cover", "Delete"); AlertDialog.Builder(requireContext()).setTitle(s.title).setItems(opts) { _, w -> if (w == 0) startCoverEdit(s) else deleteSongs(listOf(s)) }.show() }
    private fun startCoverEdit(s: Song) { songToEdit = s; pickImageLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }

    private fun updateSongCover(s: Song, uri: Uri) {
        lifecycleScope.launch(Dispatchers.IO) {
            val ctx = requireContext()
            val editor = CoverEditor(ctx)
            val result = editor.updateCover(s, uri)

            if (result.isSuccess) {
                val changedAt = System.currentTimeMillis()
                val fallbackDirtySong = s.copy(
                    isDirty = true,
                    modifiedTime = changedAt
                )
                val updatedSong = metadataReader.readMetadata(ctx, Uri.parse(s.filePath))
                val finalSong = updatedSong?.copy(
                    id = s.id,
                    isFavourite = s.isFavourite,
                    isDirty = true,
                    modifiedTime = changedAt,
                    favLastUpdated = s.favLastUpdated
                ) ?: fallbackDirtySong

                songDao.updateSong(finalSong)

                withContext(Dispatchers.Main) {
                    songAdapter.setSelectionMode(false)
                    refresh()
                    Toast.makeText(ctx, "Cover Updated Successfully", Toast.LENGTH_SHORT).show()
                }
            } else {
                withContext(Dispatchers.Main) {
                    val error = result.exceptionOrNull()?.message ?: "Unknown error"
                    Toast.makeText(ctx, "Error: $error", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun toggleFav(s: Song) {
        lifecycleScope.launch(Dispatchers.IO) {
            val updated = s.copy(isFavourite = !s.isFavourite, favLastUpdated = System.currentTimeMillis())
            songDao.updateSong(updated)
            withContext(Dispatchers.Main) {
                val songs = songAdapter.getSongs().toMutableList()
                val idx = songs.indexOfFirst { it.id == s.id }
                if (idx != -1) {
                    songs[idx] = updated
                    songAdapter.updateSongs(songs)
                    songAdapter.notifyItemChanged(idx)
                }
            }
        }
    }

    private fun deleteSongs(songs: List<Song>) {
        AlertDialog.Builder(requireContext())
            .setTitle("Delete Songs")
            .setMessage("Are you sure you want to delete ${songs.size} songs from storage?")
            .setPositiveButton("Delete") { _, _ ->
                lifecycleScope.launch(Dispatchers.IO) {
                    for (s in songs) {
                        try {
                            val uri = Uri.parse(s.filePath)
                            DocumentFile.fromSingleUri(requireContext(), uri)?.delete()
                            songDao.deleteSongsByIds(listOf(s.id))
                        } catch (e: Exception) { e.printStackTrace() }
                    }
                    withContext(Dispatchers.Main) {
                        songAdapter.setSelectionMode(false)
                        refresh()
                    }
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun scan() {
        val savedUri = syncManager.getMusicDirectoryUri()
        if (savedUri != null) {
            startScan(Uri.parse(savedUri))
        } else {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            startActivityForResult(intent, 1001)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 1001 && resultCode == android.app.Activity.RESULT_OK) {
            data?.data?.let { uri ->
                requireContext().contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                syncManager.setMusicDirectoryUri(uri.toString())
                startScan(uri)
            }
        }
    }

    private fun startScan(treeUri: Uri) {
        scanProgressBar?.visibility = View.VISIBLE
        lifecycleScope.launch(Dispatchers.IO) {
            val rootDoc = DocumentFile.fromTreeUri(requireContext(), treeUri)
            if (rootDoc == null || !rootDoc.exists() || !rootDoc.isDirectory) {
                withContext(Dispatchers.Main) {
                    scanProgressBar?.visibility = View.GONE
                    Toast.makeText(requireContext(), "Cannot access directory", Toast.LENGTH_SHORT).show()
                }
                return@launch
            }

            val audioFiles = mutableListOf<DocumentFile>()
            collectAudioFiles(rootDoc, audioFiles)

            val total = audioFiles.size
            if (total == 0) {
                withContext(Dispatchers.Main) {
                    scanProgressBar?.visibility = View.GONE
                    Toast.makeText(requireContext(), "No music files found", Toast.LENGTH_SHORT).show()
                }
                return@launch
            }

            val existingSongs = songDao.getAllSongs().associateBy { it.filePath }

            var processed = 0
            var changed = 0
            val scannedPaths = mutableSetOf<String>()

            for (doc in audioFiles) {
                val uriStr = doc.uri.toString()
                scannedPaths.add(uriStr)
                val existing = existingSongs[uriStr]

                if (existing != null) {
                    processed++
                    if (processed % 10 == 0 || processed == total) {
                        withContext(Dispatchers.Main) { scanProgressBar?.progress = (processed * 100) / total }
                    }
                    continue
                }

                val song = metadataReader.readMetadata(requireContext(), doc.uri)
                if (song != null) {
                    val dup = songDao.getSongByHash(song.fileHash)
                    if (dup == null) {
                        songDao.insertSong(song)
                    } else if (dup.filePath != uriStr) {
                        songDao.updateSong(dup.copy(filePath = uriStr))
                    }
                    changed++
                }
                processed++
                if (processed % 10 == 0 || processed == total) {
                    withContext(Dispatchers.Main) { scanProgressBar?.progress = (processed * 100) / total }
                }
            }

            val removedPaths = existingSongs.keys - scannedPaths
            if (removedPaths.isNotEmpty()) {
                val removedIds = existingSongs.filterKeys { it in removedPaths }.map { it.value.id }
                songDao.deleteSongsByIds(removedIds)
            }

            withContext(Dispatchers.Main) {
                scanProgressBar?.visibility = View.GONE
                val msg = if (removedPaths.isNotEmpty()) "Scan done: $changed new, ${removedPaths.size} removed"
                          else "Scan done: $changed new"
                Toast.makeText(requireContext(), msg, Toast.LENGTH_SHORT).show()
                refresh()
            }
        }
    }

    private fun collectAudioFiles(dir: DocumentFile, result: MutableList<DocumentFile>) {
        val files = dir.listFiles()
        for (f in files) {
            if (f.isDirectory) {
                collectAudioFiles(f, result)
            } else if (f.isFile && AudioFileValidator.isAudioFile(f.name)) {
                result.add(f)
            }
        }
    }

    private fun refresh() {
        lifecycleScope.launch(Dispatchers.IO) {
            val songs = when (currentTab) {
                1 -> songDao.getFavouriteSongs()
                else -> songDao.getAllSongs()
            }.filter { it.title.contains(searchQuery, true) || it.artist.contains(searchQuery, true) }

            val sorted = when (currentSortOrder) {
                0 -> songs.sortedBy { it.title.lowercase() }
                1 -> songs.sortedBy { it.artist.lowercase() }
                else -> songs.sortedByDescending { it.modifiedTime }
            }

            withContext(Dispatchers.Main) { songAdapter.updateSongs(sorted) }
        }
    }

    /**
     * Play a song from search results using the FULL (unfiltered) song list as the playlist.
     * This ensures that after the song ends, ExoPlayer auto-advances to the next song
     * in the full library rather than being stuck in the search-filtered subset.
     */
    private fun playSongFromSearch(clickedSong: Song) {
        lifecycleScope.launch(Dispatchers.IO) {
            val fullList = when (currentTab) {
                1 -> songDao.getFavouriteSongs()
                else -> songDao.getAllSongs()
            }
            val sorted = when (currentSortOrder) {
                0 -> fullList.sortedBy { it.title.lowercase() }
                1 -> fullList.sortedBy { it.artist.lowercase() }
                else -> fullList.sortedByDescending { it.modifiedTime }
            }
            val index = sorted.indexOfFirst { it.fileHash == clickedSong.fileHash }
            if (index >= 0) {
                withContext(Dispatchers.Main) {
                    PlayerManager.play(sorted, index)
                }
            }
        }
    }

    private fun setupPlayerListener() {
        val player = activePlayer() ?: return
        observedPlayer?.removeListener(playerListener)
        observedPlayer = player
        player.addListener(playerListener)
    }

    private fun activePlayer(): Player? {
        return mediaController ?: PlayerManager.getController() ?: PlayerManager.getPlayer()
    }

    private var lastSwipedPosition: Int = -1
    private var swipeThresholdExecuted: Boolean = false

    private fun setupSwipeHandler(recyclerView: RecyclerView) {
        val swipeThresholdRatio = 0.3f // 30% width to trigger

        val callback = object : ItemTouchHelper.SimpleCallback(0, ItemTouchHelper.LEFT or ItemTouchHelper.RIGHT) {
            override fun onMove(recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder, target: RecyclerView.ViewHolder): Boolean = false

            override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
                val position = viewHolder.bindingAdapterPosition
                songAdapter.notifyItemChanged(position)
                
                if (swipeThresholdExecuted) {
                    val song = songAdapter.getSongs()[position]
                    PlayerManager.playNext(song)
                    Toast.makeText(requireContext(), "Added to Play Next: ${song.title}", Toast.LENGTH_SHORT).show()
                    
                    lastSwipedPosition = -1
                    swipeThresholdExecuted = false
                }
            }

            override fun onChildDraw(c: Canvas, r: RecyclerView, viewHolder: RecyclerView.ViewHolder, dX: Float, dY: Float, s: Int, a: Boolean) {
                val itemView = viewHolder.itemView
                val screenWidth = itemView.width.toFloat()
                val threshold = screenWidth * swipeThresholdRatio
                
                val p = Paint()

                if (!swipeThresholdExecuted && (dX > threshold || dX < -threshold)) {
                    swipeThresholdExecuted = true
                    lastSwipedPosition = viewHolder.bindingAdapterPosition
                    triggerHapticFeedback()
                } else if (swipeThresholdExecuted && dX < threshold && dX > -threshold) {
                    swipeThresholdExecuted = false
                }

                if (dX > 0 || dX < 0) {
                    p.color = if (swipeThresholdExecuted) Color.parseColor("#2196F3") else Color.parseColor("#442196F3")
                    
                    if (dX > 0) {
                        c.drawRect(RectF(itemView.left.toFloat(), itemView.top.toFloat(), dX, itemView.bottom.toFloat()), p)
                    } else {
                        c.drawRect(RectF(itemView.right.toFloat() + dX, itemView.top.toFloat(), itemView.right.toFloat(), itemView.bottom.toFloat()), p)
                    }
                }
                
                super.onChildDraw(c, r, viewHolder, dX, dY, s, a)
            }

            override fun clearView(recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder) {
                super.clearView(recyclerView, viewHolder)
                lastSwipedPosition = -1
                swipeThresholdExecuted = false
            }
        }
        ItemTouchHelper(callback).attachToRecyclerView(recyclerView)
    }

    private fun triggerHapticFeedback() {
        try {
            val vibrator = requireContext().getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(VibrationEffect.createOneShot(50, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(50)
            }
        } catch (e: Exception) {
            // Ignore if vibration fails or permission is missing
        }
    }
}
