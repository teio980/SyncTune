package com.example.synctune.player

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.example.synctune.R
import com.example.synctune.library.PlaybackCacheHelper
import com.example.synctune.ui.MainActivity
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null
    private var playbackCacheHelper: PlaybackCacheHelper? = null

    companion object {
        const val COMMAND_CYCLE_PLAYBACK_MODE = "COMMAND_CYCLE_PLAYBACK_MODE"
        private const val NOTIFICATION_ID = 1

        fun shouldStop(player: Player?): Boolean {
            return player == null || player.mediaItemCount == 0
        }
    }

    @UnstableApi
    override fun onCreate() {
        super.onCreate()
        try {
            playbackCacheHelper = PlaybackCacheHelper(this)
        } catch (e: Exception) {
            e.printStackTrace()
        }
        val player = PlayerManager.getPlayer(this)
        
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("open_now_playing", true)
        }
        
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        mediaSession = MediaSession.Builder(this, player)
            .setSessionActivity(pendingIntent)
            .setCallback(CustomMediaSessionCallback())
            .build()

        // Android 12+ requires foreground service notification within seconds.
        // Start foreground immediately with idle notification, even if no media is loaded.
        // Media3 will replace this with a proper playback notification once playing.
        startForeground(NOTIFICATION_ID, buildIdleNotification())

        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                updateCustomLayout()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (!isPlaying) {
                    saveCurrentPosition()
                }
                updateCustomLayout()
            }

            override fun onEvents(player: Player, events: Player.Events) {
                if (events.contains(Player.EVENT_MEDIA_METADATA_CHANGED) || 
                    events.contains(Player.EVENT_PLAYBACK_STATE_CHANGED) ||
                    events.contains(Player.EVENT_PLAY_WHEN_READY_CHANGED)) {
                    updateCustomLayout()
                }
            }

            override fun onRepeatModeChanged(repeatMode: Int) {
                updateCustomLayout()
            }
            override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) {
                updateCustomLayout()
            }
        })
        
        updateCustomLayout()
    }

    private fun saveCurrentPosition() {
        try {
            playbackCacheHelper?.let { helper ->
                val player = PlayerManager.getPlayer(this)
                if (player.mediaItemCount > 0 && player.duration > 0) {
                    val item = player.currentMediaItem
                    if (item != null) {
                        val songHash = item.mediaId
                        val uri = item.localConfiguration?.uri?.toString()
                        val filePath = when {
                            uri?.startsWith("file://") == true -> uri.removePrefix("file://")
                            else -> uri
                        }
                        if (filePath != null && player.currentPosition > 0) {
                            helper.saveCache(songHash, filePath, player.currentPosition, player.repeatMode, player.shuffleModeEnabled)
                        }
                    }
                }
            }
        } catch (e: Throwable) {
            e.printStackTrace()
        }
    }

    private fun buildIdleNotification(): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, "default_notification_channel")
            .setContentTitle(getString(R.string.app_name))
            .setContentText("准备就绪")
            .setContentIntent(pendingIntent)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
    }

    @UnstableApi
    override fun onUpdateNotification(
        session: MediaSession,
        startInForeground: Boolean
    ) {
        super.onUpdateNotification(session, startInForeground)
    }

    private fun updateCustomLayout() {
        val session = mediaSession ?: return
        val player = session.player
        
        val (iconRes, label) = when {
            player.shuffleModeEnabled -> {
                R.drawable.ic_shuffle to "随机播放"
            }
            player.repeatMode == Player.REPEAT_MODE_ONE -> {
                R.drawable.ic_repeat_one to "单曲循环"
            }
            else -> {
                R.drawable.ic_repeat to "列表循环"
            }
        }

        val playbackModeButton = CommandButton.Builder()
            .setSessionCommand(SessionCommand(COMMAND_CYCLE_PLAYBACK_MODE, Bundle.EMPTY))
            .setIconResId(iconRes)
            .setDisplayName(label)
            .setEnabled(true)
            .build()

        session.setCustomLayout(listOf(playbackModeButton))
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (shouldStop(mediaSession?.player)) {
            stopSelf()
        }
    }

    private inner class CustomMediaSessionCallback : MediaSession.Callback {
        @UnstableApi
        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo
        ): MediaSession.ConnectionResult {
            val sessionCommands = MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                .add(SessionCommand(COMMAND_CYCLE_PLAYBACK_MODE, Bundle.EMPTY))
                .build()
            
            val playerCommands = Player.Commands.Builder()
                .addAllCommands()
                .build()

            return MediaSession.ConnectionResult.accept(sessionCommands, playerCommands)
        }

        @UnstableApi
        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle
        ): ListenableFuture<SessionResult> {
            val player = session.player
            if (customCommand.customAction == COMMAND_CYCLE_PLAYBACK_MODE) {
                cyclePlaybackMode(player)
                return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
            }
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED))
        }
        
        private fun cyclePlaybackMode(player: Player) {
            when {
                !player.shuffleModeEnabled && player.repeatMode == Player.REPEAT_MODE_ALL -> {
                    player.repeatMode = Player.REPEAT_MODE_ONE
                    player.shuffleModeEnabled = false
                }
                !player.shuffleModeEnabled && player.repeatMode == Player.REPEAT_MODE_ONE -> {
                    player.repeatMode = Player.REPEAT_MODE_ALL
                    player.shuffleModeEnabled = true
                }
                else -> {
                    player.repeatMode = Player.REPEAT_MODE_ALL
                    player.shuffleModeEnabled = false
                }
            }
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return mediaSession
    }

    override fun onDestroy() {
        saveCurrentPosition()
        mediaSession?.run {
            release()
            mediaSession = null
        }
        PlayerManager.releasePlayer()
        super.onDestroy()
    }
}
