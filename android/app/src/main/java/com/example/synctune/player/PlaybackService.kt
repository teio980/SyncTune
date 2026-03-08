package com.example.synctune.player

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
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
        
        // 设置 SessionActivity，确保点击灵动岛/胶囊能正确跳回 App
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

        // 监听播放器状态，用于在切换模式时更新灵动岛/通知栏图标
        player.addListener(object : Player.Listener {
            override fun onRepeatModeChanged(repeatMode: Int) {
                updateCustomLayout()
            }
            override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) {
                updateCustomLayout()
            }
        })
        
        updateCustomLayout()
    }

    /**
     * 更新通知栏和系统的自定义按钮布局（适配灵动岛/胶囊控制）
     */
    private fun updateCustomLayout() {
        val player = mediaSession?.player ?: return
        
        // 根据当前状态选择显示的图标
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

        // 设置自定义布局，Media3 会将其推送到系统控制中心/胶囊
        mediaSession?.setCustomLayout(listOf(playbackModeButton))
    }

    private inner class CustomMediaSessionCallback : MediaSession.Callback {
        @UnstableApi
        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo
        ): MediaSession.ConnectionResult {
            // 允许所有基础指令 + 我们的自定义模式切换指令
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
                // 注意：updateCustomLayout 会在 player 监听器中被调用
                return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
            }
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED))
        }
        
        private fun cyclePlaybackMode(player: Player) {
            when {
                !player.shuffleModeEnabled && player.repeatMode == Player.REPEAT_MODE_ALL -> {
                    // 列表循环 -> 单曲循环
                    player.repeatMode = Player.REPEAT_MODE_ONE
                    player.shuffleModeEnabled = false
                }
                !player.shuffleModeEnabled && player.repeatMode == Player.REPEAT_MODE_ONE -> {
                    // 单曲循环 -> 随机播放
                    player.repeatMode = Player.REPEAT_MODE_ALL
                    player.shuffleModeEnabled = true
                }
                else -> {
                    // 随机播放 -> 列表循环
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
            player.release()
            release()
            mediaSession = null
        }
        super.onDestroy()
    }
}
