package com.example.synctune.ui.nowplaying

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.GradientDrawable
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.animation.AnimationUtils
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.SeekBar
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.fragment.app.Fragment
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.palette.graphics.Palette
import com.example.synctune.R
import com.example.synctune.player.PlayerManager
import com.google.android.material.floatingactionbutton.FloatingActionButton
import java.io.File
import java.util.Locale

class NowPlayingFragment : Fragment() {

    private var albumArt: ImageView? = null
    private var songTitle: TextView? = null
    private var artistAlbum: TextView? = null
    private var seekBar: SeekBar? = null
    private var currentTime: TextView? = null
    private var totalTime: TextView? = null
    private var btnPlayPause: FloatingActionButton? = null
    private var btnShuffle: ImageButton? = null
    private var btnRepeat: ImageButton? = null
    private var backgroundGradient: View? = null
    
    private val handler = Handler(Looper.getMainLooper())
    private val updateProgressAction = object : Runnable {
        override fun run() {
            updateProgress()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        val view = inflater.inflate(R.layout.fragment_now_playing, container, false)
        
        initViews(view)
        setupPlayerListener()
        
        val player = PlayerManager.getPlayer(requireContext())
        updateUI(player.currentMediaItem)
        updatePlayPauseIcon(player.isPlaying)
        updateRepeatModeIcon(player.repeatMode)
        updateShuffleModeIcon(player.shuffleModeEnabled)
        
        return view
    }

    private fun initViews(view: View) {
        albumArt = view.findViewById(R.id.iv_album_art)
        songTitle = view.findViewById(R.id.tv_player_title)
        artistAlbum = view.findViewById(R.id.tv_player_artist_album)
        seekBar = view.findViewById(R.id.player_seekbar)
        currentTime = view.findViewById(R.id.tv_current_time)
        totalTime = view.findViewById(R.id.tv_total_time)
        btnPlayPause = view.findViewById(R.id.btn_play_pause)
        btnShuffle = view.findViewById(R.id.btn_shuffle)
        btnRepeat = view.findViewById(R.id.btn_repeat)
        backgroundGradient = view.findViewById(R.id.background_gradient)

        val btnClickAnim = AnimationUtils.loadAnimation(requireContext(), R.anim.btn_click)

        view.findViewById<ImageButton>(R.id.btn_close).setOnClickListener {
            it.startAnimation(btnClickAnim)
            parentFragmentManager.popBackStack()
        }

        btnPlayPause?.setOnClickListener {
            it.startAnimation(btnClickAnim)
            val player = PlayerManager.getPlayer(requireContext())
            if (player.isPlaying) player.pause() else player.play()
        }

        view.findViewById<ImageButton>(R.id.btn_next).setOnClickListener {
            it.startAnimation(btnClickAnim)
            PlayerManager.getPlayer(requireContext()).seekToNext()
        }

        view.findViewById<ImageButton>(R.id.btn_prev).setOnClickListener {
            it.startAnimation(btnClickAnim)
            PlayerManager.getPlayer(requireContext()).seekToPrevious()
        }

        btnShuffle?.setOnClickListener {
            it.startAnimation(btnClickAnim)
            val player = PlayerManager.getPlayer(requireContext())
            player.shuffleModeEnabled = !player.shuffleModeEnabled
        }

        btnRepeat?.setOnClickListener {
            it.startAnimation(btnClickAnim)
            val player = PlayerManager.getPlayer(requireContext())
            player.repeatMode = when (player.repeatMode) {
                Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
                Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
                else -> Player.REPEAT_MODE_OFF
            }
        }

        seekBar?.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                if (fromUser) {
                    PlayerManager.getPlayer(requireContext()).seekTo(progress.toLong())
                }
            }
            override fun onStartTrackingTouch(seekBar: SeekBar?) {}
            override fun onStopTrackingTouch(seekBar: SeekBar?) {}
        })
    }

    private fun setupPlayerListener() {
        val player = PlayerManager.getPlayer(requireContext())
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                updateUI(mediaItem)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                updatePlayPauseIcon(isPlaying)
                if (isPlaying) {
                    handler.post(updateProgressAction)
                } else {
                    handler.removeCallbacks(updateProgressAction)
                }
            }

            override fun onRepeatModeChanged(repeatMode: Int) {
                updateRepeatModeIcon(repeatMode)
            }

            override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) {
                updateShuffleModeIcon(shuffleModeEnabled)
            }
        })
    }

    private fun updateUI(mediaItem: MediaItem?) {
        if (!isAdded) return
        
        mediaItem?.let {
            val metadata = it.mediaMetadata
            songTitle?.text = metadata.title ?: "Unknown Title"
            val artist = metadata.artist ?: "Unknown Artist"
            val album = metadata.albumTitle ?: "Unknown Album"
            artistAlbum?.text = "$artist - $album"
            
            val bitmap = getAlbumArt(it) ?: getDefaultBitmap()
            albumArt?.setImageBitmap(bitmap)
            albumArt?.startAnimation(AnimationUtils.loadAnimation(requireContext(), android.R.anim.fade_in))
            updateBackgroundColor(bitmap)
        }
    }

    private fun getAlbumArt(mediaItem: MediaItem): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            val path = mediaItem.localConfiguration?.uri.toString()
            val uri = Uri.parse(path)
            if (path.startsWith("content://")) {
                requireContext().contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                    retriever.setDataSource(pfd.fileDescriptor)
                }
            } else {
                retriever.setDataSource(path)
            }
            val art = retriever.embeddedPicture
            if (art != null) BitmapFactory.decodeByteArray(art, 0, art.size) else null
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    private fun getDefaultBitmap(): Bitmap {
        val drawable = ContextCompat.getDrawable(requireContext(), R.drawable.default_album_art)
        if (drawable is BitmapDrawable) {
            return drawable.bitmap
        }
        
        val bitmap = Bitmap.createBitmap(500, 500, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable?.setBounds(0, 0, canvas.width, canvas.height)
        drawable?.draw(canvas)
        return bitmap
    }

    private fun updateBackgroundColor(bitmap: Bitmap) {
        if (!isAdded) return
        
        Palette.from(bitmap).generate { palette ->
            if (!isAdded) return@generate
            
            val dominantColor = palette?.getDominantColor(ContextCompat.getColor(requireContext(), R.color.black)) ?: 0
            val darkMutedColor = palette?.getDarkMutedColor(ContextCompat.getColor(requireContext(), R.color.black)) ?: 0
            
            val gradient = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(dominantColor, darkMutedColor, ContextCompat.getColor(requireContext(), R.color.black))
            )
            backgroundGradient?.background = gradient
        }
    }

    private fun updatePlayPauseIcon(isPlaying: Boolean) {
        btnPlayPause?.setImageResource(if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play)
    }

    private fun updateRepeatModeIcon(repeatMode: Int) {
        if (!isAdded) return
        
        val isEnabled = repeatMode != Player.REPEAT_MODE_OFF
        val color = if (isEnabled) {
            ContextCompat.getColor(requireContext(), R.color.white)
        } else {
            ContextCompat.getColor(requireContext(), R.color.white).let { c ->
                android.graphics.Color.argb(100, android.graphics.Color.red(c), android.graphics.Color.green(c), android.graphics.Color.blue(c))
            }
        }
        
        btnRepeat?.setColorFilter(color)
        
        if (repeatMode == Player.REPEAT_MODE_ONE) {
            btnRepeat?.setImageResource(R.drawable.ic_repeat_one)
        } else {
            btnRepeat?.setImageResource(R.drawable.ic_repeat)
        }
    }

    private fun updateShuffleModeIcon(enabled: Boolean) {
        if (!isAdded) return
        val color = if (enabled) {
            ContextCompat.getColor(requireContext(), R.color.white)
        } else {
            ContextCompat.getColor(requireContext(), R.color.white).let { c ->
                android.graphics.Color.argb(100, android.graphics.Color.red(c), android.graphics.Color.green(c), android.graphics.Color.blue(c))
            }
        }
        btnShuffle?.setColorFilter(color)
    }

    private fun updateProgress() {
        if (!isAdded) return
        
        val player = PlayerManager.getPlayer(requireContext())
        if (player.duration > 0) {
            seekBar?.max = player.duration.toInt()
            seekBar?.progress = player.currentPosition.toInt()
            currentTime?.text = formatTime(player.currentPosition)
            totalTime?.text = formatTime(player.duration)
        }
    }

    private fun formatTime(ms: Long): String {
        val totalSeconds = if (ms > 0) ms / 1000 else 0
        val seconds = totalSeconds % 60
        val minutes = (totalSeconds / 60) % 60
        return String.format(Locale.getDefault(), "%02d:%02d", minutes, seconds)
    }

    override fun onResume() {
        super.onResume()
        if (PlayerManager.getPlayer(requireContext()).isPlaying) {
            handler.post(updateProgressAction)
        }
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(updateProgressAction)
    }
}
