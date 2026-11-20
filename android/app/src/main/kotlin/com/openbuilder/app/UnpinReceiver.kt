package com.openbuilder.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/// Holds the keepalive MethodChannel attached in MainActivity so the service
/// / receiver side can reach Dart while the engine is alive. InvokeMethod must
/// run on the main thread; failures (engine detached) degrade to the Kotlin
/// side only (design-live-updates §2.5).
object KeepaliveChannels {
    private const val TAG = "OpenBuilder/KeepaliveChannel"

    @Volatile
    private var channel: MethodChannel? = null

    fun attach(channel: MethodChannel) {
        this.channel = channel
    }

    fun detach() {
        channel = null
    }

    fun notifyUnpinFromNotification() {
        val ch = channel ?: return
        Handler(Looper.getMainLooper()).post {
            try {
                ch.invokeMethod("onUnpinFromNotification", null)
            } catch (e: Exception) {
                Log.w(TAG, "unpin invoke failed: ${e.message}")
            }
        }
    }
}

/// Handles the watcher notification's Unpin action ("Stop notifications") and
/// the Live Update deleteIntent (design-live-updates §2.5 / LU-D4 / LU-D5).
class UnpinReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_UNPIN -> {
                context.stopService(Intent(context, KeepaliveService::class.java))
                KeepaliveChannels.notifyUnpinFromNotification()
            }
            ACTION_DISMISSED -> KeepaliveService.promotedSuppressed = true
        }
    }

    companion object {
        const val ACTION_UNPIN = "com.openbuilder.app.action.UNPIN_WATCH"
        const val ACTION_DISMISSED = "com.openbuilder.app.action.WATCH_DISMISSED"
    }
}
