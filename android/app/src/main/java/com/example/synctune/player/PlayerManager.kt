package com.example.synctune.player

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import com.example.synctune.library.Song
import com.example.synctune.ui.MainActivity

object PlayerManager {

    private var exoPlayer: ExoPlayer? = null
    private var mediaSession: MediaSession? = null
    private var currentPlaylistPaths: List<String>? = null

    fun getPlayer(context: Context): ExoPlayer {
        if (exoPlayer == null) {
            val appContext = context.applicationContext
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                .build()

            exoPlayer = ExoPlayer.Builder(appContext)
                .setAudioAttributes(audioAttributes, true)
                .build()
            
            exoPlayer!!.repeatMode = Player.REPEAT_MODE_ALL

            // 创建点击灵动岛/胶囊时跳转的回道 Intent
            val intent = Intent(appContext, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("open_now_playing", true) // 标记需要跳转到播放详情页
            }
            
            val pendingIntent = PendingIntent.getActivity(
                appContext, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            // 荣耀灵动岛（胶囊）需要 MediaSession 支持
            mediaSession = MediaSession.Builder(appContext, exoPlayer!!)
                .setSessionActivity(pendingIntent) // 设置点击后的跳转行为
                .build()
        }
        return exoPlayer!!
    }

    fun play(context: Context, songs: List<Song>, startIndex: Int) {
        val player = getPlayer(context)
        val newPaths = songs.map { it.filePath }
        
        if (currentPlaylistPaths != null && currentPlaylistPaths == newPaths) {
            val isShuffle = player.shuffleModeEnabled
            if (isShuffle) player.shuffleModeEnabled = false
            
            player.seekTo(startIndex, 0)
            
            if (isShuffle) player.shuffleModeEnabled = true

            player.prepare()
            player.play()
            return
        }

        currentPlaylistPaths = newPaths
        val mediaItems = songs.map { song ->
            val metadata = MediaMetadata.Builder()
                .setTitle(song.title)
                .setArtist(song.artist)
                .setAlbumTitle(song.album)
                .build()

            MediaItem.Builder()
                .setUri(Uri.parse(song.filePath))
                .setMediaMetadata(metadata)
                .build()
        }
        
        player.setMediaItems(mediaItems, startIndex, 0)
        player.prepare()
        player.play()
    }

    fun releasePlayer() {
        mediaSession?.release()
        mediaSession = null
        exoPlayer?.release()
        exoPlayer = null
        currentPlaylistPaths = null
    }
}
