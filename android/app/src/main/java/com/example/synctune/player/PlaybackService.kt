package com.example.synctune.player

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.example.synctune.R
import com.example.synctune.ui.MainActivity
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null

    companion object {
        const val COMMAND_CYCLE_PLAYBACK_MODE = "COMMAND_CYCLE_PLAYBACK_MODE"
    }

    @UnstableApi
    override fun onCreate() {
        super.onCreate()
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

        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                // 当媒体项切换时，强制更新自定义布局以触发通知刷新
                updateCustomLayout()
            }

            override fun onEvents(player: Player, events: Player.Events) {
                // 监听元数据或播放状态变化
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
        val player = mediaSession?.player
        if (player == null || !player.playWhenReady || player.playbackState == Player.STATE_IDLE) {
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
        mediaSession?.run {
            release()
            mediaSession = null
        }
        PlayerManager.releasePlayer()
        super.onDestroy()
    }
}
