package com.example.synctune.player

import android.content.Context
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
                .setDisplayTitle(song.title)
                .setSubtitle(song.artist)
                .build()

            MediaItem.Builder()
                .setMediaId(song.fileHash)
                .setUri(Uri.parse(song.filePath))
                .setMediaMetadata(metadata)
                .build()
        }
        
        player.setMediaItems(mediaItems, startIndex, 0)
        player.prepare()
        player.play()
    }

    fun releasePlayer() {
        exoPlayer?.release()
        exoPlayer = null
        currentPlaylistPaths = null
    }
}
