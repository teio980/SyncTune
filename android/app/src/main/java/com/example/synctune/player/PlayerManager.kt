package com.example.synctune.player

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import com.example.synctune.library.PlaybackCache
import com.example.synctune.library.Song
import java.io.File

object PlayerManager {

    private var exoPlayer: ExoPlayer? = null
    private var currentPlaylistPaths: List<String>? = null
    private var mediaController: MediaController? = null

    fun setServicePlayer(player: ExoPlayer) {
        exoPlayer = player
    }

    fun clearServicePlayer() {
        exoPlayer = null
        currentPlaylistPaths = null
    }

    fun getPlayer(): ExoPlayer? {
        return exoPlayer
    }

    fun setController(controller: MediaController?) {
        mediaController = controller
    }

    fun getController(): MediaController? {
        return mediaController
    }

    fun play(context: Context, songs: List<Song>, startIndex: Int) {
        val player = mediaController ?: exoPlayer ?: return
        
        val newPaths = songs.map { it.filePath }
        val currentSong = if (startIndex < songs.size) songs[startIndex] else null

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
            
            currentSong?.let { song ->
                try {
                    PlaybackCache.save(
                        context,
                        song.fileHash,
                        song.filePath,
                        0L,
                        player.repeatMode,
                        player.shuffleModeEnabled
                    )
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }
        player.playWhenReady = true
    }

    /**
     * 将歌曲添加到"下一首播放"
     */
    fun playNext(song: Song) {
        val player = mediaController ?: exoPlayer ?: return

        val mediaItem = createMediaItem(song)

        if (player.mediaItemCount == 0 || player.playbackState == Player.STATE_IDLE) {
            // 如果没在播放，直接设为当前并播放
            player.setMediaItem(mediaItem)
            player.prepare()
            player.play()
        } else {
            // 插入到当前索引的下一位置
            val nextIndex = player.currentMediaItemIndex + 1
            player.addMediaItem(nextIndex, mediaItem)
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

    internal fun createMediaItems(songs: List<Song>): List<MediaItem> {
        return songs.map { createMediaItem(it) }
    }

    internal fun createMediaItem(song: Song): MediaItem {
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

    fun restoreFromCache(song: Song, position: Long, repeatMode: Int, shuffleMode: Boolean) {
        val player = mediaController ?: exoPlayer ?: return
        currentPlaylistPaths = listOf(song.filePath)
        val mediaItem = createMediaItem(song)
        player.setMediaItem(mediaItem)
        player.seekTo(position)
        player.repeatMode = repeatMode
        player.shuffleModeEnabled = shuffleMode
        player.prepare()
        player.playWhenReady = false
    }
}
