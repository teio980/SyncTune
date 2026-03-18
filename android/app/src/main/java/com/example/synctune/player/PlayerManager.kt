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
import java.io.File

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
            exoPlayer!!.playWhenReady = true
        }
        return exoPlayer!!
    }

    private fun ensureServiceStarted(context: Context) {
        val intent = Intent(context.applicationContext, PlaybackService::class.java)
        context.startService(intent)
    }

    fun play(context: Context, songs: List<Song>, startIndex: Int) {
        val player = getPlayer(context)
        ensureServiceStarted(context)
        
        val newPaths = songs.map { it.filePath }

        if (currentPlaylistPaths != null && currentPlaylistPaths == newPaths) {
            val isShuffle = player.shuffleModeEnabled
            if (isShuffle) player.shuffleModeEnabled = false
            player.seekTo(startIndex, 0L)
            if (isShuffle) player.shuffleModeEnabled = true
            player.prepare()
            player.play()
        } else {
            currentPlaylistPaths = newPaths
            val mediaItems = createMediaItems(songs)
            player.setMediaItems(mediaItems, startIndex, 0L)
            player.prepare()
            player.play()
        }
        player.playWhenReady = true
    }

    /**
     * 将歌曲添加到“下一首播放”
     */
    fun playNext(context: Context, song: Song) {
        val player = getPlayer(context)
        ensureServiceStarted(context)

        val mediaItem = createMediaItem(song)

        // 如果当前正在播放，插入到当前索引的下一位置
        val nextIndex = if (player.currentMediaItemIndex != -1) {
            player.currentMediaItemIndex + 1
        } else {
            0
        }

        player.addMediaItem(nextIndex, mediaItem)

        // 如果当前没有在播放（列表为空），直接开始播放
        if (player.playbackState == Player.STATE_IDLE || player.mediaItemCount == 1) {
            player.prepare()
            player.play()
        }
    }

    fun updateMediaItemMetadata(song: Song) {
        val player = exoPlayer ?: return
        for (i in 0 until player.mediaItemCount) {
            val mediaItem = player.getMediaItemAt(i)
            if (mediaItem.mediaId == song.fileHash) {
                val updatedMetadata = MediaMetadata.Builder()
                    .setTitle(song.title)
                    .setArtist(song.artist)
                    .setAlbumTitle(song.album)
                    .setDisplayTitle(song.title)
                    .setSubtitle(song.artist)
                    .setArtworkUri(Uri.fromFile(File(song.filePath)))
                    .build()

                val updatedMediaItem = mediaItem.buildUpon()
                    .setMediaMetadata(updatedMetadata)
                    .build()

                player.replaceMediaItem(i, updatedMediaItem)
            }
        }
    }

    private fun createMediaItems(songs: List<Song>): List<MediaItem> {
        return songs.map { createMediaItem(it) }
    }

    private fun createMediaItem(song: Song): MediaItem {
        val metadata = MediaMetadata.Builder()
            .setTitle(song.title)
            .setArtist(song.artist)
            .setAlbumTitle(song.album)
            .setDisplayTitle(song.title)
            .setSubtitle(song.artist)
            .setArtworkUri(Uri.fromFile(File(song.filePath)))
            .setIsPlayable(true)
            .build()

        return MediaItem.Builder()
            .setMediaId(song.fileHash)
            .setUri(Uri.parse(song.filePath))
            .setMediaMetadata(metadata)
            .build()
    }

    fun releasePlayer() {
        exoPlayer?.release()
        exoPlayer = null
        currentPlaylistPaths = null
    }
}
