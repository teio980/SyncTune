package com.example.synctune.ui.library

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.text.*
import android.view.*
import android.widget.*
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.widget.PopupMenu
import androidx.documentfile.provider.DocumentFile
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.Player
import androidx.recyclerview.widget.*
import com.example.synctune.R
import com.example.synctune.library.*
import com.example.synctune.player.PlayerManager
import com.example.synctune.sync.*
import com.google.android.material.card.MaterialCardView
import com.google.android.material.progressindicator.LinearProgressIndicator
import com.google.android.material.tabs.TabLayout
import com.google.android.material.textfield.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.*
import org.jaudiotagger.audio.AudioFileIO
import org.jaudiotagger.tag.images.*
import org.jaudiotagger.tag.reference.PictureTypes
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

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

    private val syncReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == SyncWorker.ACTION_SYNC_COMPLETED) {
                // 当后台同步完成，立即在主线程刷新列表
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
        songAdapter = SongAdapter(emptyList(), { s -> val all = songAdapter.getSongs(); PlayerManager.play(requireContext(), all, all.indexOf(s)) },
            { s -> showSongOptions(s) }, { s -> toggleFav(s) }, { c -> updateUI(v, c) })
        v.findViewById<RecyclerView>(R.id.recycler_view_songs).apply { layoutManager = LinearLayoutManager(context); adapter = songAdapter; setupSwipeHandler(this) }
        v.findViewById<TabLayout>(R.id.tab_layout_library).addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(t: TabLayout.Tab?) { currentTab = t?.position ?: 0; refresh() }
            override fun onTabUnselected(t: TabLayout.Tab?) {}; override fun onTabReselected(t: TabLayout.Tab?) {}
        })
        v.findViewById<MaterialCardView>(R.id.card_scan).setOnClickListener { scan() }
        setupSearch(v); refresh()
        
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
    }

    override fun onStop() {
        super.onStop()
        requireContext().unregisterReceiver(syncReceiver)
    }
    
    private fun syncCurrentPlayingPath() {
        val player = PlayerManager.getPlayer(requireContext())
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
        v.findViewById<View>(R.id.btn_search).setOnClickListener { if (til.visibility == View.GONE) { til.visibility = View.VISIBLE; et.requestFocus() } else { til.visibility = View.GONE; et.text?.clear(); searchQuery = ""; refresh() } }
        et.addTextChangedListener(object : TextWatcher {
            override fun onTextChanged(s: CharSequence?, st: Int, b: Int, c: Int) { searchQuery = s?.toString() ?: ""; refresh() }
            override fun beforeTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}; override fun afterTextChanged(p0: Editable?) {}
        })
        v.findViewById<View>(R.id.btn_sort).setOnClickListener { val p = PopupMenu(requireContext(), it); p.menu.add(0,0,0,"Name"); p.menu.add(0,1,1,"Artist"); p.menu.add(0,2,2,"Date"); p.setOnMenuItemClickListener { i -> currentSortOrder = i.itemId; refresh(); true }; p.show() }
        v.findViewById<View>(R.id.btn_cancel_selection).setOnClickListener { songAdapter.setSelectionMode(false) }
        v.findViewById<View>(R.id.btn_delete_selected).setOnClickListener { val s = songAdapter.getSelectedSongs(); if (s.isNotEmpty()) deleteSongs(s) }
        v.findViewById<View>(R.id.btn_edit_selected).setOnClickListener { val s = songAdapter.getSelectedSongs(); if (s.size == 1) startCoverEdit(s[0]) }
    }

    private fun showSongOptions(s: Song) { val opts = arrayOf("Edit Cover", "Delete"); AlertDialog.Builder(requireContext()).setTitle(s.title).setItems(opts) { _, w -> if (w == 0) startCoverEdit(s) else deleteSongs(listOf(s)) }.show() }
    private fun startCoverEdit(s: Song) { songToEdit = s; pickImageLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }

    private fun updateSongCover(s: Song, uri: Uri) {
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                val ctx = requireContext()
                val aUri = Uri.parse(s.filePath)
                org.jaudiotagger.tag.TagOptionSingleton.getInstance().isAndroid = true
                
                val extension = s.fileName.substringAfterLast(".", "mp3")
                val tmp = File(ctx.cacheDir, "edit_${System.currentTimeMillis()}.$extension")
                
                ctx.contentResolver.openInputStream(aUri)?.use { i -> tmp.outputStream().use { o -> i.copyTo(o) } } ?: throw Exception("Read failed")
                
                val imgBytes = ctx.contentResolver.openInputStream(uri)?.readBytes() ?: throw Exception("Image read failed")
                val af = AudioFileIO.read(tmp)
                val tag = af.tag ?: af.createDefaultTag()
                
                tag.deleteArtworkField()
                val art = ArtworkFactory.getNew()
                art.binaryData = imgBytes
                art.mimeType = ctx.contentResolver.getType(uri) ?: "image/jpeg"
                art.pictureType = PictureTypes.DEFAULT_ID
                tag.setField(art)
                af.commit()

                ctx.contentResolver.openFileDescriptor(aUri, "rwt")?.use { pfd ->
                    val outChannel = FileOutputStream(pfd.fileDescriptor).channel
                    outChannel.truncate(0) 
                    FileInputStream(tmp).use { fis ->
                        val inChannel = fis.channel
                        inChannel.transferTo(0, inChannel.size(), outChannel)
                    }
                    outChannel.force(true)
                } ?: throw Exception("Write back failed")
                
                tmp.delete()
                
                val upMetadata = metadataReader.readMetadata(ctx, aUri) ?: return@launch
                val updatedSong = upMetadata.copy(
                    id = s.id, 
                    isFavourite = s.isFavourite, 
                    isDirty = true, 
                    modifiedTime = System.currentTimeMillis()
                )
                
                songDao.updateSong(updatedSong)
                
                withContext(Dispatchers.Main) { 
                    PlayerManager.updateMediaItemMetadata(updatedSong)
                    songAdapter.setSelectionMode(false)
                    
                    val songs = songAdapter.getSongs().toMutableList()
                    val index = songs.indexOfFirst { it.id == s.id }
                    if (index != -1) {
                        songs[index] = updatedSong
                        songAdapter.updateSongs(songs)
                        songAdapter.notifyItemChanged(index)
                    }
                    
                    Toast.makeText(ctx, "Cover Updated Successfully", Toast.LENGTH_SHORT).show()
                    if (syncManager.isSyncEnabled()) syncManager.startImmediateSync("UPLOAD") 
                }
            } catch (e: Exception) { 
                e.printStackTrace()
                withContext(Dispatchers.Main) { Toast.makeText(requireContext(), "Error: ${e.message}", Toast.LENGTH_SHORT).show() } 
            }
        }
    }

    private fun scan() {
        val rootStr = requireActivity().getSharedPreferences("SyncTunePrefs", Context.MODE_PRIVATE).getString("music_directory_uri", null) ?: return
        val root = Uri.parse(rootStr); scanProgressBar?.visibility = View.VISIBLE; scanProgressBar?.isIndeterminate = true
        lifecycleScope.launch(Dispatchers.IO) {
            val local = listFiles(requireContext(), root); val db = songDao.getAllSongsSorted().associateBy { it.filePath }
            val toProc = local.filter { it.mod > (db[it.uri.toString()]?.modifiedTime ?: 0L) }
            if (toProc.isNotEmpty()) {
                withContext(Dispatchers.Main) { scanProgressBar?.apply { isIndeterminate = false; max = toProc.size; progress = 0 } }
                val sem = Semaphore(4); coroutineScope { toProc.mapIndexed { i, f -> async { sem.withPermit {
                    metadataReader.readMetadata(requireContext(), f.uri)?.let { s -> 
                        val ex = db[f.uri.toString()]
                        if (ex != null) songDao.updateSong(s.copy(id = ex.id, isFavourite = ex.isFavourite, isDirty = false)) 
                        else songDao.insertSong(s.copy(isDirty = false)) 
                    }
                    if (i % 10 == 0) withContext(Dispatchers.Main) { scanProgressBar?.progress = i }
                } } }.awaitAll() }
            }
            val localUris = local.map { it.uri.toString() }.toSet()
            val toDelete = db.values.filter { !localUris.contains(it.filePath) }.map { it.id }
            if (toDelete.isNotEmpty()) songDao.deleteSongsByIds(toDelete)
            
            withContext(Dispatchers.Main) { scanProgressBar?.visibility = View.GONE; refresh() }
        }
    }

    private fun listFiles(ctx: Context, root: Uri): List<FInfo> {
        val res = mutableListOf<FInfo>(); val stack = mutableListOf<String>(); stack.add(DocumentsContract.getTreeDocumentId(root))
        while (stack.isNotEmpty()) {
            val pid = stack.removeAt(stack.size - 1); val cur = DocumentsContract.buildChildDocumentsUriUsingTree(root, pid)
            ctx.contentResolver.query(cur, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { c ->
                val idI = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID); val nameI = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeI = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE); val modI = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                while (c.moveToNext()) {
                    val id = c.getString(idI); val n = c.getString(nameI) ?: continue; val m = c.getString(mimeI)
                    if (m == DocumentsContract.Document.MIME_TYPE_DIR) stack.add(id) else if (AudioFileValidator.isAudioFile(n) && !n.startsWith(".")) res.add(FInfo(DocumentsContract.buildDocumentUriUsingTree(root, id), c.getLong(modI)))
                }
            }
        }
        return res
    }

    private data class FInfo(val uri: Uri, val mod: Long)
    private fun deleteSongs(songs: List<Song>) {
        lifecycleScope.launch(Dispatchers.IO) { 
            songs.forEach { s -> Uri.parse(s.filePath)?.let { DocumentFile.fromSingleUri(requireContext(), it)?.delete() } }
            songDao.deleteSongsByIds(songs.map { it.id })
            withContext(Dispatchers.Main) { songAdapter.setSelectionMode(false); refresh(); if (syncManager.isSyncEnabled()) syncManager.startImmediateSync("TWO_WAY") }
        }
    }

    private fun toggleFav(s: Song) { 
        lifecycleScope.launch(Dispatchers.IO) { 
            songDao.updateFavouriteStatus(s.id, !s.isFavourite)
            withContext(Dispatchers.Main) { 
                refresh()
                if (syncManager.isSyncEnabled()) {
                    syncManager.startImmediateSync("TWO_WAY")
                }
            } 
        } 
    }

    private fun refresh() {
        lifecycleScope.launch(Dispatchers.IO) {
            val order = when (currentSortOrder) { 0 -> "title"; 1 -> "artist"; else -> "date" }
            val songs = if (currentTab == 1) songDao.getFavouriteSongs(order) else songDao.getAllSongsSorted(order)
            val filtered = if (searchQuery.isEmpty()) songs else songs.filter { it.title.contains(searchQuery, true) || it.artist.contains(searchQuery, true) }
            withContext(Dispatchers.Main) { songAdapter.updateSongs(filtered) }
        }
    }
    
    private fun setupSwipeHandler(rv: RecyclerView) {
        ItemTouchHelper(object : ItemTouchHelper.SimpleCallback(0, ItemTouchHelper.LEFT or ItemTouchHelper.RIGHT) {
            override fun onMove(r: RecyclerView, v: RecyclerView.ViewHolder, t: RecyclerView.ViewHolder) = false
            override fun onSwiped(vh: RecyclerView.ViewHolder, d: Int) {
                val s = songAdapter.getSongs()[vh.bindingAdapterPosition]
                toggleFav(s)
            }
        }).attachToRecyclerView(rv)
    }

    private fun setupPlayerListener() {
        PlayerManager.getPlayer(requireContext()).addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: androidx.media3.common.MediaItem?, reason: Int) {
                val currentUri = mediaItem?.localConfiguration?.uri?.toString()
                songAdapter.setPlayingSongPath(currentUri)
            }
        })
    }
}
