package com.example.synctune.ui.library

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.animation.AnimationUtils
import android.widget.CheckBox
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.RecyclerView
import com.bumptech.glide.Glide
import com.bumptech.glide.load.engine.DiskCacheStrategy
import com.bumptech.glide.load.resource.drawable.DrawableTransitionOptions
import com.bumptech.glide.signature.ObjectKey
import com.example.synctune.R
import com.example.synctune.library.Song
import kotlinx.coroutines.*

class SongAdapter(
    private var songs: List<Song>,
    private val onItemClick: (Song) -> Unit,
    private val onItemLongClick: (Song) -> Unit,
    private val onFavouriteClick: (Song) -> Unit,
    private val onSelectionChanged: (Int) -> Unit
) : RecyclerView.Adapter<SongAdapter.SongViewHolder>() {

    private var playingSongPath: String? = null
    private var isSelectionMode = false
    private val selectedSongs = mutableSetOf<Song>()
    
    private val adapterScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    class SongViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val title: TextView = view.findViewById(R.id.tv_song_title)
        val artist: TextView = view.findViewById(R.id.tv_song_artist)
        val albumArt: ImageView = view.findViewById(R.id.iv_song_album_art)
        val playingIndicator: ImageView = view.findViewById(R.id.iv_playing_indicator)
        val checkBox: CheckBox = view.findViewById(R.id.cb_song_select)
        val btnFavourite: ImageButton = view.findViewById(R.id.btn_favourite)
        var thumbnailJob: Job? = null
    }

    fun isSelectionModeEnabled(): Boolean = isSelectionMode

    fun setSelectionMode(enabled: Boolean) {
        if (isSelectionMode != enabled) {
            isSelectionMode = enabled
            if (!enabled) selectedSongs.clear()
            notifyDataSetChanged()
            onSelectionChanged(selectedSongs.size)
        }
    }

    fun getSelectedSongs(): List<Song> = selectedSongs.toList()

    fun getSongs(): List<Song> = songs

    fun setPlayingSongPath(path: String?) {
        playingSongPath = path
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): SongViewHolder {
        val view = LayoutInflater.from(parent.context).inflate(R.layout.item_song, parent, false)
        return SongViewHolder(view)
    }

    override fun onBindViewHolder(holder: SongViewHolder, position: Int) {
        val song = songs[position]
        val isPlaying = song.filePath == playingSongPath

        holder.title.text = song.title
        holder.artist.text = "${song.artist} • ${song.album}"
        
        if (isPlaying) {
            holder.title.setTextColor(ContextCompat.getColor(holder.itemView.context, R.color.purple_500))
            holder.playingIndicator.visibility = if (isSelectionMode) View.GONE else View.VISIBLE
        } else {
            holder.title.setTextColor(ContextCompat.getColor(holder.itemView.context, R.color.white))
            holder.playingIndicator.visibility = View.GONE
        }

        holder.checkBox.visibility = if (isSelectionMode) View.VISIBLE else View.GONE
        holder.checkBox.setOnCheckedChangeListener(null)
        holder.checkBox.isChecked = selectedSongs.contains(song)
        holder.checkBox.setOnCheckedChangeListener { _, isChecked ->
            if (isChecked) selectedSongs.add(song) else selectedSongs.remove(song)
            onSelectionChanged(selectedSongs.size)
        }

        holder.btnFavourite.visibility = if (isSelectionMode) View.GONE else View.VISIBLE
        updateFavouriteIcon(holder.btnFavourite, song.isFavourite)
        
        holder.btnFavourite.setOnClickListener {
            it.startAnimation(AnimationUtils.loadAnimation(it.context, R.anim.btn_click))
            onFavouriteClick(song)
        }

        holder.thumbnailJob?.cancel()
        
        holder.thumbnailJob = adapterScope.launch {
            // 立即清除旧 Glide 请求并设为默认图，彻底断开与旧缓存的联系
            Glide.with(holder.itemView.context).clear(holder.albumArt)
            holder.albumArt.setImageResource(R.drawable.default_album_art)

            val artData = withContext(Dispatchers.IO) {
                getAlbumArt(holder.itemView.context, song.filePath)
            }
            
            if (isActive) {
                Glide.with(holder.itemView.context)
                    .load(artData)
                    // 核心修复：更强的签名，包含修改时间
                    .signature(ObjectKey("${song.filePath}_${song.modifiedTime}"))
                    // 禁止 Glide 在这种情况下使用内存缓存，确保从 artData 重新解码
                    .skipMemoryCache(true)
                    .diskCacheStrategy(DiskCacheStrategy.NONE)
                    .placeholder(R.drawable.default_album_art)
                    .error(R.drawable.default_album_art)
                    .transition(DrawableTransitionOptions.withCrossFade())
                    .into(holder.albumArt)
            }
        }

        holder.itemView.setOnClickListener {
            if (isSelectionMode) {
                holder.checkBox.toggle()
            } else {
                it.startAnimation(AnimationUtils.loadAnimation(it.context, R.anim.btn_click))
                onItemClick(song)
            }
        }

        holder.itemView.setOnLongClickListener {
            if (!isSelectionMode) {
                selectedSongs.add(song)
                setSelectionMode(true)
            } else {
                onItemLongClick(song)
            }
            true
        }
    }

    private fun updateFavouriteIcon(view: ImageButton, isFavourite: Boolean) {
        view.setImageResource(R.drawable.ic_heart)
        if (isFavourite) {
            view.setColorFilter(ContextCompat.getColor(view.context, R.color.purple_500))
        } else {
            view.setColorFilter(ContextCompat.getColor(view.context, R.color.white))
        }
    }

    private fun getAlbumArt(context: Context, path: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        return try {
            val uri = Uri.parse(path)
            if (path.startsWith("content://")) {
                context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                    retriever.setDataSource(pfd.fileDescriptor)
                }
            } else {
                retriever.setDataSource(path)
            }
            retriever.embeddedPicture
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    override fun getItemCount() = songs.size

    fun updateSongs(newSongs: List<Song>) {
        songs = newSongs
        notifyDataSetChanged()
    }
    
    fun clear() {
        adapterScope.cancel()
    }
}
