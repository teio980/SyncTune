package com.example.synctune.player

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.common.Player
import com.example.synctune.library.Song
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentCaptor
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.robolectric.RuntimeEnvironment
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PlayerManagerTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        legacyPlaybackCachePrefs().edit().clear().commit()
        PlayerManager.setController(null)
        PlayerManager.clearServicePlayer()
    }

    @After
    fun tearDown() {
        legacyPlaybackCachePrefs().edit().clear().commit()
        PlayerManager.setController(null)
        PlayerManager.clearServicePlayer()
    }

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
        val controller = mock(Player::class.java)

        PlayerManager.setController(controller)

        assertEquals(controller, PlayerManager.getController())
    }

    @Test
    fun controllerHolder_canBeCleared() {
        PlayerManager.setController(mock(Player::class.java))

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

    @Test
    fun play_doesNotWriteLegacySharedPreferencesCache_whenStartingSong() {
        val controller = mock(Player::class.java)
        val songs = listOf(song(filePath = "/music/cached.mp3", fileHash = "cached-hash"))
        PlayerManager.setController(controller)

        PlayerManager.play(songs, 0)

        assertNull(legacyPlaybackCachePrefs().getString("song_hash", null))
    }

    @Test
    fun restoreFromCache_preparesSingleItemAndRestoresPlaybackModeWithoutAutoplay() {
        val controller = mock(Player::class.java)
        val song = song(
            title = "Cached Song",
            artist = "Cached Artist",
            album = "Cached Album",
            filePath = "/music/cached.mp3",
            fileHash = "cached-hash",
        )

        PlayerManager.setController(controller)

        PlayerManager.restoreFromCache(
            song = song,
            position = 42_000L,
            repeatMode = Player.REPEAT_MODE_ONE,
            shuffleMode = true,
        )

        val itemCaptor = ArgumentCaptor.forClass(MediaItem::class.java)
        verify(controller).setMediaItem(itemCaptor.capture())
        assertEquals("cached-hash", itemCaptor.value.mediaId)
        verify(controller).seekTo(42_000L)
        verify(controller).setRepeatMode(Player.REPEAT_MODE_ONE)
        verify(controller).setShuffleModeEnabled(true)
        verify(controller).prepare()
        verify(controller).setPlayWhenReady(false)
    }

    private fun legacyPlaybackCachePrefs() =
        context.getSharedPreferences("playback_cache", Context.MODE_PRIVATE)

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
