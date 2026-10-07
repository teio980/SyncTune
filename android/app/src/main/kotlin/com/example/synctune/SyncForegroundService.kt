package com.example.synctune

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class SyncForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "synctune_sync_channel"
        const val NOTIFICATION_ID = 9527

        const val ACTION_START = "com.example.synctune.action.START_SYNC"
        const val ACTION_UPDATE = "com.example.synctune.action.UPDATE_SYNC"
        const val ACTION_FINISH = "com.example.synctune.action.FINISH_SYNC"
        const val ACTION_CANCEL = "com.example.synctune.action.CANCEL_SYNC"

        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_MESSAGE = "extra_message"
        const val EXTRA_PROGRESS = "extra_progress"
        const val EXTRA_MAX = "extra_max"
        const val EXTRA_INDETERMINATE = "extra_indeterminate"
        const val EXTRA_SUCCESS = "extra_success"

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context, title: String, message: String) {
            val intent = Intent(context, SyncForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_MESSAGE, message)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun update(
            context: Context,
            title: String,
            message: String,
            progress: Int? = null,
            max: Int? = null,
            indeterminate: Boolean = false,
        ) {
            val intent = Intent(context, SyncForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_MESSAGE, message)
                if (progress != null) putExtra(EXTRA_PROGRESS, progress)
                if (max != null) putExtra(EXTRA_MAX, max)
                putExtra(EXTRA_INDETERMINATE, indeterminate)
            }
            context.startService(intent)
        }

        fun finish(context: Context, title: String, message: String, success: Boolean) {
            val intent = Intent(context, SyncForegroundService::class.java).apply {
                action = ACTION_FINISH
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_MESSAGE, message)
                putExtra(EXTRA_SUCCESS, success)
            }
            context.startService(intent)
        }

        fun cancel(context: Context) {
            val intent = Intent(context, SyncForegroundService::class.java).apply {
                action = ACTION_CANCEL
            }
            context.startService(intent)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit var notificationManager: NotificationManager

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: return START_NOT_STICKY

        when (action) {
            ACTION_START -> {
                isRunning = true
                acquireWakeLock()
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "SyncTune"
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "Syncing…"
                val notification = buildNotification(title, message, ongoing = true, indeterminate = true)
                startForegroundCompat(notification)
            }
            ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "SyncTune"
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "Syncing…"
                val progress = if (intent.hasExtra(EXTRA_PROGRESS)) intent.getIntExtra(EXTRA_PROGRESS, 0) else null
                val max = if (intent.hasExtra(EXTRA_MAX)) intent.getIntExtra(EXTRA_MAX, 0) else null
                val indeterminate = intent.getBooleanExtra(EXTRA_INDETERMINATE, false)

                val notification = buildNotification(
                    title,
                    message,
                    ongoing = true,
                    progress = progress,
                    max = max,
                    indeterminate = indeterminate,
                )
                notificationManager.notify(NOTIFICATION_ID, notification)
            }
            ACTION_FINISH -> {
                isRunning = false
                releaseWakeLock()
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "SyncTune"
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "Sync complete"

                stopForegroundCompat(removeNotification = false)
                val notification = buildNotification(
                    title,
                    message,
                    ongoing = false,
                    autoCancel = true,
                )
                notificationManager.notify(NOTIFICATION_ID, notification)
                stopSelf()
            }
            ACTION_CANCEL -> {
                isRunning = false
                releaseWakeLock()
                stopForegroundCompat(removeNotification = true)
                notificationManager.cancel(NOTIFICATION_ID)
                stopSelf()
            }
        }

        return START_NOT_STICKY
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat(removeNotification: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(if (removeNotification) STOP_FOREGROUND_REMOVE else STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(removeNotification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "SyncTune Synchronization",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows progress and status during music synchronization"
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(
        title: String,
        message: String,
        ongoing: Boolean,
        progress: Int? = null,
        max: Int? = null,
        indeterminate: Boolean = false,
        autoCancel: Boolean = false,
    ): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(contentIntent)
            .setOngoing(ongoing)
            .setAutoCancel(autoCancel)

        if (ongoing) {
            if (indeterminate) {
                builder.setProgress(0, 0, true)
            } else if (progress != null && max != null && max > 0) {
                builder.setProgress(max, progress, false)
            }
        } else {
            builder.setProgress(0, 0, false)
        }

        return builder.build()
    }

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "synctune:sync_service_wakelock")
        }
        if (wakeLock?.isHeld == false) {
            wakeLock?.acquire(60 * 60 * 1000L)
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        isRunning = false
        releaseWakeLock()
        super.onDestroy()
    }
}
