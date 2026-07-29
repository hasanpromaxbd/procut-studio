package com.procutstudio.procut_studio

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
import androidx.core.app.NotificationCompat

/**
 * Keeps a render alive while the app is in the background.
 *
 * ## What this actually buys, and what it does not
 *
 * FFmpeg runs inside the Flutter process, so this service does **not** move the
 * encode elsewhere. What it does is promote the process to foreground
 * importance, which puts it near the bottom of the low-memory killer's list.
 * The practical effect is that an export survives the user leaving the app,
 * the screen turning off, and memory pressure from other apps — which is what
 * kills long exports in the real world.
 *
 * It does **not** survive a force-stop or a reboot. Nothing short of a separate
 * process would, and that would mean shipping FFmpeg twice.
 *
 * ## Foreground service types
 *
 * `mediaProcessing` only exists from API 34. Below that the closest accurate
 * type is `dataSync`, and below API 29 types do not exist at all. Declaring the
 * wrong type on Android 14+ is a hard crash
 * (`MissingForegroundServiceTypeException`), so the version split is not
 * optional.
 */
class ExportService : Service() {

    companion object {
        const val ACTION_START = "com.procutstudio.procut_studio.EXPORT_START"
        const val ACTION_UPDATE = "com.procutstudio.procut_studio.EXPORT_UPDATE"
        const val ACTION_STOP = "com.procutstudio.procut_studio.EXPORT_STOP"
        const val ACTION_CANCEL = "com.procutstudio.procut_studio.EXPORT_CANCEL"

        const val EXTRA_TITLE = "title"
        const val EXTRA_MESSAGE = "message"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_INDETERMINATE = "indeterminate"

        private const val CHANNEL_ID = "procut_export"
        private const val NOTIFICATION_ID = 4201

        /**
         * Invoked when the user taps Cancel on the notification.
         *
         * Set by [MainActivity], which owns the Flutter engine and forwards the
         * request to Dart. A plain nullable callback rather than a bound
         * service: binding buys nothing here and adds a lifecycle to get wrong.
         */
        @Volatile
        var onCancelRequested: (() -> Unit)? = null

        fun start(context: Context, title: String, message: String) {
            val intent = Intent(context, ExportService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_MESSAGE, message)
            }
            ContextCompat_startForegroundService(context, intent)
        }

        fun update(
            context: Context,
            message: String,
            progress: Int,
            indeterminate: Boolean
        ) {
            val intent = Intent(context, ExportService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_MESSAGE, message)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_INDETERMINATE, indeterminate)
            }
            ContextCompat_startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ExportService::class.java))
        }

        private fun ContextCompat_startForegroundService(
            context: Context,
            intent: Intent
        ) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private var currentTitle: String = "Exporting"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                currentTitle = intent.getStringExtra(EXTRA_TITLE) ?: "Exporting"
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "Preparing"
                startInForeground(buildNotification(message, 0, true))
            }

            ACTION_UPDATE -> {
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: ""
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val indeterminate = intent.getBooleanExtra(EXTRA_INDETERMINATE, false)
                notificationManager().notify(
                    NOTIFICATION_ID,
                    buildNotification(message, progress, indeterminate)
                )
            }

            ACTION_CANCEL -> {
                onCancelRequested?.invoke()
                // The Dart side tears the job down and then calls stop(); doing
                // it here as well would race the final progress event.
            }

            ACTION_STOP -> stopSelfCleanly()
        }

        // Do not restart automatically: the render state lives in the Dart
        // isolate, so a service resurrected without it would show a progress
        // bar for a job that no longer exists.
        return START_NOT_STICKY
    }

    private fun startInForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopSelfCleanly() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun buildNotification(
        message: String,
        progress: Int,
        indeterminate: Boolean
    ): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val cancelIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, ExportService::class.java).apply { action = ACTION_CANCEL },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(currentTitle)
            .setContentText(message)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setProgress(100, progress, indeterminate)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setContentIntent(contentIntent)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Cancel",
                cancelIntent
            )
            .build()
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Video export",
            // LOW: a progress bar should never make a sound or vibrate. IMPORTANCE_MIN
            // would hide it from the shade, which defeats the purpose.
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows progress while a video is being exported"
            setShowBadge(false)
            enableVibration(false)
        }
        notificationManager().createNotificationChannel(channel)
    }

    override fun onDestroy() {
        onCancelRequested = null
        super.onDestroy()
    }
}
