package com.openbuilder.app

import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

class KeepaliveService : Service() {

    private var startedActivities = 0

    private val lifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            startedActivities++
            if (startedActivities == 1) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            }
        }

        override fun onActivityStopped(activity: Activity) {
            startedActivities--
            if (startedActivities <= 0) {
                startedActivities = 0
                showNotification()
            }
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

        override fun onActivityResumed(activity: Activity) {}

        override fun onActivityPaused(activity: Activity) {}

        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

        override fun onActivityDestroyed(activity: Activity) {}
    }

    override fun onCreate() {
        super.onCreate()
        startedActivities = OpenBuilderApplication.startedActivities
        application.registerActivityLifecycleCallbacks(lifecycleCallbacks)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val count = intent?.getIntExtra(EXTRA_COUNT, -1) ?: -1
        if (count > 0) {
            lastCount = count
        }
        // start deliveries (startForegroundService) must call startForeground
        // within 5s; updateCount deliveries call it anyway to refresh the
        // posted text while backgrounded. Hidden again right away while the
        // app is foreground.
        startForeground(
            NOTIF_ID,
            buildNotification(lastCount),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )
        if (startedActivities > 0) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "dataSync timeout (type=$fgsType) — stopping keepalive")
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        stopSelf()
    }

    override fun onDestroy() {
        application.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /// Re-promote while the app transitions out of the visible state; this is
    /// an explicit exemption from the background FGS start restrictions. On
    /// rejection (OEM variants) the service stays a plain started service of a
    /// backgrounded app and the system stops it within about a minute —
    /// observation is lost, never a crash (BN-R21).
    private fun showNotification() {
        try {
            startForeground(
                NOTIF_ID,
                buildNotification(lastCount),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } catch (e: Exception) {
            Log.w(TAG, "fgs promote rejected: ${e.message}")
        }
    }

    private fun buildNotification(count: Int): Notification {
        val text =
            resources.getQuantityString(R.plurals.keepalive_running_tasks, count, count)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Open Builder")
            .setContentText(text)
            .setContentIntent(launchIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    /// Direct PendingIntent to the activity: not a notification trampoline, so
    /// the Android 12 trampoline ban does not apply. Bringing the app forward
    /// flips the started-activity count, and the D20 hide path removes the
    /// notification without needing autoCancel.
    private fun launchIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    companion object {
        private const val TAG = "OpenBuilder/Keepalive"
        const val CHANNEL_ID = "watching"
        const val NOTIF_ID = -100
        const val EXTRA_COUNT = "count"
        private var lastCount = 1
    }
}
