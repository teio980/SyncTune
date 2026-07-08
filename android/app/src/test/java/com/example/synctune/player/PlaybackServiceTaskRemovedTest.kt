package com.example.synctune.player

import androidx.media3.common.Player
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`

class PlaybackServiceTaskRemovedTest {
    @Test
    fun shouldStop_whenPlayerIsNull() {
        assertTrue(PlaybackService.shouldStop(null))
    }

    @Test
    fun shouldStop_whenPlayerHasNoMedia() {
        val player = mock(Player::class.java)
        `when`(player.mediaItemCount).thenReturn(0)

        assertTrue(PlaybackService.shouldStop(player))
    }

    @Test
    fun keepsService_whenPlayerHasQueuedMedia() {
        val player = mock(Player::class.java)
        `when`(player.mediaItemCount).thenReturn(3)

        assertFalse(PlaybackService.shouldStop(player))
    }
}
