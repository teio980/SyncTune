package com.synctune.core.player

import com.synctune.core.model.Song
import uk.co.caprica.vlcj.factory.discovery.NativeDiscovery
import uk.co.caprica.vlcj.player.base.MediaPlayer
import uk.co.caprica.vlcj.player.component.AudioPlayerComponent
import java.io.File

interface PlayerManager {
    fun play(song: Song)
    fun pause()
    fun resume()
    fun stop()
    fun isPlaying(): Boolean
    fun currentSong(): Song?
    fun currentPosition(): Float // 0.0 to 1.0
    fun seekTo(position: Float)
}

class DesktopPlayerManager : PlayerManager {
    private var mediaPlayerComponent: AudioPlayerComponent? = null
    private var currentSong: Song? = null
    private var isPaused = false
    private var isVlcAvailable = false

    init {
        try {
            isVlcAvailable = NativeDiscovery().discover()
            if (isVlcAvailable) {
                mediaPlayerComponent = AudioPlayerComponent()
            }
        } catch (e: Throwable) {
            isVlcAvailable = false
            println("VLC not found or failed to load: ${e.message}")
        }
    }

    override fun play(song: Song) {
        if (!isVlcAvailable) return
        val file = File(song.filePath)
        if (file.exists()) {
            mediaPlayerComponent?.mediaPlayer()?.media()?.play(file.absolutePath)
            currentSong = song
            isPaused = false
        }
    }

    override fun pause() {
        if (!isVlcAvailable) return
        if (isPlaying()) {
            mediaPlayerComponent?.mediaPlayer()?.controls()?.pause()
            isPaused = true
        }
    }

    override fun resume() {
        if (!isVlcAvailable) return
        if (isPaused) {
            mediaPlayerComponent?.mediaPlayer()?.controls()?.play()
            isPaused = false
        }
    }

    override fun stop() {
        if (!isVlcAvailable) return
        mediaPlayerComponent?.mediaPlayer()?.controls()?.stop()
        currentSong = null
        isPaused = false
    }

    override fun isPlaying(): Boolean {
        return isVlcAvailable && (mediaPlayerComponent?.mediaPlayer()?.status()?.isPlaying ?: false)
    }

    override fun currentSong(): Song? = currentSong

    override fun currentPosition(): Float {
        if (!isVlcAvailable) return 0f
        return mediaPlayerComponent?.mediaPlayer()?.status()?.position() ?: 0f
    }

    override fun seekTo(position: Float) {
        if (!isVlcAvailable) return
        mediaPlayerComponent?.mediaPlayer()?.controls()?.setPosition(position)
    }

    fun isAvailable() = isVlcAvailable

    fun release() {
        mediaPlayerComponent?.release()
    }
}
