package com.example.synctune.player

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer

class MusicPlayer(private val context: Context) {

    private var exoPlayer: ExoPlayer? = null

    fun initializePlayer() {
        exoPlayer = ExoPlayer.Builder(context).build()
    }

    fun play(mediaItem: MediaItem) {
        exoPlayer?.setMediaItem(mediaItem)
        exoPlayer?.prepare()
        exoPlayer?.play()
    }

    fun pause() {
        exoPlayer?.pause()
    }

    fun seekTo(positionMs: Long) {
        exoPlayer?.seekTo(positionMs)
    }

    fun releasePlayer() {
        exoPlayer?.release()
        exoPlayer = null
    }
}
