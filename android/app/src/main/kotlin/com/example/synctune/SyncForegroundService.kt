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
import android.os.ResultReceiver

class SyncForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "synctune_sync_channel"
        const val NOTIFICATION_ID = 9527
        const val ACTION_START = "com.example.synctune.action.START_SYNC"
        const val ACTION_UPDATE = "com.example.synctune.action.UPDATE_SYNC"
        const val ACTION_FINISH = "com.example.synctune.action.FINISH_SYNC"
        const val ACTION_CANCEL = "com.example.synctune.action.CANCEL_SYNC"
        const val EXTRA_RECEIVER = "extra_result_receiver"
        const val EXTRA_PHASE = "extra_phase"
        const val EXTRA_FILE = "extra_current_file"
        const val EXTRA_DONE = "extra_files_done"
        const val EXTRA_COUNT = "extra_file_count"
        private const val RESULT_STARTED = 1
        private const val RESULT_FAILED = 0

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context, receiver: ResultReceiver) {
            val intent = Intent(context, SyncForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RECEIVER, receiver)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
            else context.startService(intent)
        }

        fun update(context: Context, phase: String, currentFile: String, done: Int, count: Int) {
            context.startService(Intent(context, SyncForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_PHASE, phase)
                putExtra(EXTRA_FILE, currentFile)
                putExtra(EXTRA_DONE, done)
                putExtra(EXTRA_COUNT, count)
            })
        }

        fun finish(context: Context, message: String) {
            context.startService(Intent(context, SyncForegroundService::class.java).apply {
                action = ACTION_FINISH
                putExtra(EXTRA_PHASE, message)
            })
        }

        private fun requestStop(context: Context) {
            (context.applicationContext as? SyncTuneApplication)?.platformChannel
                ?.invokeMethod("cancelSync", null)
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
        when (intent?.action) {
            ACTION_START -> startSync(intent, startId)
            ACTION_UPDATE -> updateNotification(intent)
            ACTION_CANCEL -> requestSafeStop()
            ACTION_FINISH -> finishSync(intent)
            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun startSync(intent: Intent, startId: Int) {
        val receiver = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_RECEIVER, ResultReceiver::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RECEIVER)
        }
        try {
            startForegroundCompat(buildNotification(
                "SyncTune", "Starting synchronization…", ongoing = true, indeterminate = true))
            isRunning = true
            acquireWakeLock()
            receiver?.send(RESULT_STARTED, null)
        } catch (error: Exception) {
            isRunning = false
            releaseWakeLock()
            receiver?.send(RESULT_FAILED, android.os.Bundle().apply {
                putString("error", error.message ?: error.javaClass.simpleName)
            })
            stopSelf(startId)
        }
    }

    private fun updateNotification(intent: Intent) {
        if (!isRunning) return
        val phase = intent.getStringExtra(EXTRA_PHASE) ?: "Syncing"
        val file = intent.getStringExtra(EXTRA_FILE).orEmpty()
        val done = intent.getIntExtra(EXTRA_DONE, 0)
        val count = intent.getIntExtra(EXTRA_COUNT, 0)
        val message = when {
            file.isNotEmpty() -> file
            count > 0 -> "$phase · $done / $count"
            else -> phase
        }
        val indeterminate = count <= 0
        notificationManager.notify(NOTIFICATION_ID, buildNotification(
            "SyncTune", message, ongoing = true,
            progress = if (count > 0) done.coerceIn(0, count) else null,
            max = count.takeIf { it > 0 }, indeterminate = indeterminate))
    }

    private fun requestSafeStop() {
        if (!isRunning) {
            stopSelf()
            return
        }
        notificationManager.notify(NOTIFICATION_ID, buildNotification(
            "SyncTune", "Stopping safely…", ongoing = true, indeterminate = true,
            cancellable = false))
        requestStop(this)
    }

    private fun finishSync(intent: Intent) {
        isRunning = false
        releaseWakeLock()
        stopForegroundCompat(removeNotification = false)
        val message = intent.getStringExtra(EXTRA_PHASE) ?: "Sync stopped"
        notificationManager.notify(NOTIFICATION_ID, buildNotification(
            "SyncTune", message, ongoing = false, autoCancel = true, cancellable = false))
        stopSelf()
    }

    @android.annotation.TargetApi(35)
    override fun onTimeout(startId: Int, fgsType: Int) {
        requestStop(this)
        isRunning = false
        releaseWakeLock()
        stopForegroundCompat(removeNotification = false)
        notificationManager.notify(NOTIFICATION_ID, buildNotification(
            "SyncTune", "Sync paused by Android. Start again to recover.",
            ongoing = false, autoCancel = true, cancellable = false))
        stopSelf(startId)
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
            notificationManager.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "SyncTune Synchronization", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows progress during music synchronization"
                setShowBadge(false)
            })
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
        cancellable: Boolean = true,
    ): Notification {
        val contentIntent = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
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
        if (ongoing && cancellable) {
            val cancel = PendingIntent.getService(this, 1,
                Intent(this, SyncForegroundService::class.java).setAction(ACTION_CANCEL),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", cancel)
        }
        if (ongoing) {
            if (indeterminate) builder.setProgress(0, 0, true)
            else if (progress != null && max != null && max > 0) builder.setProgress(max, progress, false)
        } else builder.setProgress(0, 0, false)
        return builder.build()
    }

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,
                "synctune:sync_service_wakelock").apply { setReferenceCounted(false) }
        }
        if (wakeLock?.isHeld == false) wakeLock?.acquire()
    }

    private fun releaseWakeLock() {
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Exception) {}
    }

    override fun onDestroy() {
        val wasRunning = isRunning
        isRunning = false
        releaseWakeLock()
        if (wasRunning) requestStop(this)
        super.onDestroy()
    }
}
