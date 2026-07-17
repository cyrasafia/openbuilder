package com.opencode.opencode_mobile

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {

    private val channel = "com.opencode.mobile/font_weight"
    private val filesChannel = "com.opencode.mobile/files"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFontWeight" -> {
                        try {
                            val weight = getSystemFontWeight()
                            result.success(weight)
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, filesChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val srcPath = call.argument<String>("srcPath")
                        val displayName = call.argument<String>("displayName")
                        if (srcPath == null || displayName == null) {
                            result.error("invalid_args", "missing srcPath or displayName", null)
                        } else {
                            try {
                                result.success(saveToDownloads(srcPath, displayName))
                            } catch (e: Exception) {
                                result.error("save_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Save [srcPath] into the public Download folder.
    /// API 29+ uses MediaStore.Downloads (no permission needed);
    /// older API falls back to a direct file copy into the public Downloads dir.
    private fun saveToDownloads(srcPath: String, displayName: String): String {
        val src = File(srcPath)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw RuntimeException("无法在 Download 创建文件")
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(src).use { it.copyTo(out) }
                } ?: throw RuntimeException("无法打开输出流")
            } finally {
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            return uri.toString()
        } else {
            val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            if (!dir.exists()) dir.mkdirs()
            val dest = File(dir, displayName)
            src.copyTo(dest, overwrite = true)
            return dest.absolutePath
        }
    }

    /// Attempt to read the system font weight.
    /// Returns an Int (100-900) or null.
    private fun getSystemFontWeight(): Int? {
        // Method 1: Xiaomi/HyperOS stores font weight in Settings.System.
        try {
            val weight = android.provider.Settings.System.getInt(
                contentResolver,
                "font_weight",
                -1
            )
            if (weight in 100..900) return weight
        } catch (_: Exception) {}

        // Method 2: Read from Typeface.DEFAULT weight field (Android 12+).
        // Use javaClass directly (not superclass) to access Typeface's own
        // weight field. FW-2: superclass pointed to Object which has no weight.
        try {
            val typeface = android.graphics.Typeface.DEFAULT
            val field = typeface.javaClass.getDeclaredField("weight")
            field.isAccessible = true
            val w = field.getInt(typeface)
            if (w in 100..900) return w
        } catch (_: Exception) {}

        return null
    }
}
