package com.example.synctune.player

import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import com.example.synctune.library.Song
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.mockito.Mockito.mock

class PlayerManagerTest {
    @Test
    fun createMediaItem_setsIdentityAndFileUri() {
        val song = song(
            title = "Test Song",
            artist = "Test Artist",
            album = "Test Album",
            filePath = "/music/test.mp3",
            fileHash = "abc123",
        )

        val item = PlayerManager.createMediaItem(song)

        assertEquals("abc123", item.mediaId)
        assertNotNull(item.localConfiguration)
        assertEquals("/music/test.mp3", item.localConfiguration?.uri.toString())
    }

    @Test
    fun createMediaItem_setsMetadataFromSong() {
        val song = song(
            title = "Another Song",
            artist = "Another Artist",
            album = "Another Album",
            filePath = "/music/another.mp3",
            fileHash = "def456",
        )

        val item = PlayerManager.createMediaItem(song)

        assertEquals("Another Song", item.mediaMetadata.title)
        assertEquals("Another Artist", item.mediaMetadata.artist)
        assertEquals("Another Album", item.mediaMetadata.albumTitle)
    }

    @Test
    fun createMediaItems_preservesPlaylistOrder() {
        val songs = listOf(
            song(title = "A", filePath = "/a.mp3", fileHash = "hash1"),
            song(title = "B", filePath = "/b.mp3", fileHash = "hash2"),
        )

        val items = PlayerManager.createMediaItems(songs)

        assertEquals(2, items.size)
        assertEquals("hash1", items[0].mediaId)
        assertEquals("hash2", items[1].mediaId)
    }

    @Test
    fun controllerHolder_returnsLastController() {
        val controller = mock(MediaController::class.java)

        PlayerManager.setController(controller)

        assertEquals(controller, PlayerManager.getController())
    }

    @Test
    fun controllerHolder_canBeCleared() {
        PlayerManager.setController(mock(MediaController::class.java))

        PlayerManager.setController(null)

        assertEquals(null, PlayerManager.getController())
    }

    @Test
    fun getPlayer_returnsNull_whenServicePlayerIsNotSet() {
        PlayerManager.clearServicePlayer()

        assertNull(PlayerManager.getPlayer())
    }

    @Test
    fun getPlayer_returnsServicePlayer_whenServicePlayerIsSet() {
        val player = mock(ExoPlayer::class.java)

        PlayerManager.setServicePlayer(player)

        assertEquals(player, PlayerManager.getPlayer())
        PlayerManager.clearServicePlayer()
    }

    private fun song(
        title: String = "Title",
        artist: String = "Artist",
        album: String = "Album",
        filePath: String,
        fileHash: String,
    ): Song {
        return Song(
            id = 1L,
            title = title,
            artist = artist,
            album = album,
            filePath = filePath,
            fileName = filePath.substringAfterLast('/'),
            fileHash = fileHash,
            modifiedTime = 123L,
        )
    }
}
