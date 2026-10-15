package com.openbuilder.app

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.util.Log
import java.io.File

class OpenBuilderApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                startedActivities++
            }

            override fun onActivityStopped(activity: Activity) {
                if (startedActivities > 0) startedActivities--
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

            override fun onActivityResumed(activity: Activity) {}

            override fun onActivityPaused(activity: Activity) {}

            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

            override fun onActivityDestroyed(activity: Activity) {}
        })
        cleanupBloatedPrefs()
    }

    /// Defense against the historical cold-start OOM (CSM-10): if
    /// FlutterSharedPreferences.xml has bloated past the safe threshold,
    /// SharedPreferences.getInstance() → getAll() would serialize the whole
    /// map over the platform channel and crash before Dart can intervene.
    /// Delete the file here, before the Flutter engine starts.
    ///
    /// Writes the same `migrated_v1` marker the Dart migration uses, so the
    /// Dart side skips cleanly (prefs is already empty).
    private fun cleanupBloatedPrefs() {
        try {
            val filesDir = filesDir.absoluteFile // <dataDir>/files
            val dataDir = filesDir.parentFile // <dataDir>
            val cacheRoot = File(filesDir, "ob_cache")
            val marker = File(cacheRoot, "migrated_v1")
            if (marker.exists()) return

            // SharedPreferences XML lives at <dataDir>/shared_prefs/.
            val prefsFile = File(File(dataDir, "shared_prefs"), "FlutterSharedPreferences.xml")
            if (prefsFile.exists() && prefsFile.length() > BLOAT_THRESHOLD) {
                val size = prefsFile.length()
                val deleted = prefsFile.delete()
                if (deleted) {
                    cacheRoot.mkdirs()
                    marker.createNewFile()
                    Log.w(
                        TAG,
                        "Deleted bloated FlutterSharedPreferences.xml ($size B > $BLOAT_THRESHOLD); " +
                            "small settings reset to defaults (theme/showThinking)."
                    )
                } else {
                    Log.e(
                        TAG,
                        "Failed to delete bloated FlutterSharedPreferences.xml ($size B); " +
                            "Dart-side guard will retry via dart:io."
                    )
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "cleanupBloatedPrefs threw: ${e.message}", e)
        }
    }

    companion object {
        /// Authoritative started-activity count, maintained since process start.
        /// KeepaliveService seeds its own copy from it because its start
        /// delivery can land after onStop was dispatched (still inside the
        /// background-start exemption window), so "app is foreground at service
        /// creation" cannot be assumed (BN-R20).
        var startedActivities = 0
            private set
        private const val TAG = "OpenBuilder/PrefCleanup"
        private const val BLOAT_THRESHOLD = 4L * 1024 * 1024 // 4 MiB
    }
}
