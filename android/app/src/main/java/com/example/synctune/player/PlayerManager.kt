package com.example.synctune.player

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.example.synctune.library.Song

object PlayerManager {

    private var exoPlayer: ExoPlayer? = null
    private var currentPlaylistPaths: List<String>? = null

    fun getPlayer(context: Context): ExoPlayer {
        if (exoPlayer == null) {
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                .build()

            exoPlayer = ExoPlayer.Builder(context.applicationContext)
                .setAudioAttributes(audioAttributes, true)
                .setHandleAudioBecomingNoisy(true)
                .build()
            
            exoPlayer!!.repeatMode = Player.REPEAT_MODE_ALL
            // 关键：初始不要 playWhenReady，等待 prepare 完成
            exoPlayer!!.playWhenReady = true
        }
        return exoPlayer!!
    }

    private fun ensureServiceStarted(context: Context) {
        val intent = Intent(context.applicationContext, PlaybackService::class.java)
        // 在 Media3 中，MediaSessionService 应该通过 startService 启动，
        // 并在内部通过通知提升为前台服务。
        context.startService(intent)
    }

    fun play(context: Context, songs: List<Song>, startIndex: Int) {
        val player = getPlayer(context)
        
        // 关键修复：冷启动时确保 Service 被激活
        ensureServiceStarted(context)
        
        val newPaths = songs.map { it.filePath }
        
        player.playWhenReady = true

        if (currentPlaylistPaths != null && currentPlaylistPaths == newPaths) {
            val isShuffle = player.shuffleModeEnabled
            if (isShuffle) player.shuffleModeEnabled = false
            player.seekTo(startIndex, 0L)
            if (isShuffle) player.shuffleModeEnabled = true
            player.prepare()
            player.play()
        } else {
            currentPlaylistPaths = newPaths
            val mediaItems = songs.map { song ->
                val metadata = MediaMetadata.Builder()
                    .setTitle(song.title)
                    .setArtist(song.artist)
                    .setAlbumTitle(song.album)
                    .setDisplayTitle(song.title)
                    .setSubtitle(song.artist)
                    .build()

                MediaItem.Builder()
                    .setMediaId(song.fileHash)
                    .setUri(Uri.parse(song.filePath))
                    .setMediaMetadata(metadata)
                    .build()
            }
            
            player.setMediaItems(mediaItems, startIndex, 0L)
            player.prepare()
            player.play()
        }
    }

    fun releasePlayer() {
        exoPlayer?.release()
        exoPlayer = null
        currentPlaylistPaths = null
    }
}
