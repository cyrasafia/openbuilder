package com.openbuilder.app

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {

    private val channel = "com.openbuilder.app/font_weight"
    private val filesChannel = "com.openbuilder.app/files"

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
                        val mimeType = call.argument<String>("mimeType")
                        if (srcPath == null || displayName == null) {
                            result.error("invalid_args", "missing srcPath or displayName", null)
                        } else {
                            try {
                                result.success(saveToDownloads(srcPath, displayName, mimeType))
                            } catch (e: Exception) {
                                result.error("save_failed", e.message, null)
                            }
                        }
                    }
                    "openFile" -> {
                        val uri = call.argument<String>("uri")
                        val displayName = call.argument<String>("displayName")
                        val mimeType = call.argument<String>("mimeType")
                        if (uri == null) {
                            result.error("invalid_args", "missing uri", null)
                        } else {
                            try {
                                openFile(uri, resolveMimeType(displayName ?: "", mimeType, "*/*"))
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("open_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Save [srcPath] into the public Download folder via MediaStore (API 29+).
    /// No permission needed. Older API has no permission-free path to public
    /// Download, so it throws and the Dart side falls back to app storage.
    /// [mimeType] (optional) overrides extension-based detection.
    private fun saveToDownloads(srcPath: String, displayName: String, mimeType: String?): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("saveToDownloads 需要 API 29+")
        }
        val src = File(srcPath)
        if (!src.exists()) throw java.io.FileNotFoundException("源文件不存在: $srcPath")
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, resolveMimeType(displayName, mimeType))
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw RuntimeException("无法在 Download 创建文件")
        var success = false
        try {
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(src).use { it.copyTo(out) }
            } ?: throw RuntimeException("无法打开输出流")
            success = true
        } finally {
            if (success) {
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } else {
                resolver.delete(uri, null, null)
            }
        }
        return uri.toString()
    }

    private fun openFile(uriString: String, mimeType: String) {
        val uri = Uri.parse(uriString)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, null))
    }

    /// Prefer an explicit [mimeType]; else derive from the file extension;
    /// fall back to [fallback] (default text/plain for log-export, */* for open).
    private fun resolveMimeType(displayName: String, mimeType: String?, fallback: String = "text/plain"): String {
        if (!mimeType.isNullOrEmpty()) return mimeType
        val ext = displayName.substringAfterLast('.', "").lowercase()
        if (ext.isNotEmpty()) {
            val fromExt = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            if (!fromExt.isNullOrEmpty()) return fromExt
        }
        return fallback
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
            if (weight in 100..900) {
                Log.d(TAG, "method1 Settings.System font_weight = $weight")
                return weight
            }
            Log.d(TAG, "method1 Settings.System font_weight = $weight (out of range)")
        } catch (e: Exception) {
            Log.d(TAG, "method1 Settings.System font_weight threw: ${e.message}")
        }

        // Method 2: Read from Typeface.DEFAULT weight field (Android 12+).
        // Use javaClass directly (not superclass) to access Typeface's own
        // weight field. FW-2: superclass pointed to Object which has no weight.
        try {
            val typeface = android.graphics.Typeface.DEFAULT
            val field = typeface.javaClass.getDeclaredField("weight")
            field.isAccessible = true
            val w = field.getInt(typeface)
            if (w in 100..900) {
                Log.d(TAG, "method2 Typeface.DEFAULT.weight = $w")
                return w
            }
            Log.d(TAG, "method2 Typeface.DEFAULT.weight = $w (out of range)")
        } catch (e: Exception) {
            Log.d(TAG, "method2 Typeface.DEFAULT.weight threw: ${e.message}")
        }

        Log.d(TAG, "no system font weight found → null")
        return null
    }

    companion object {
        private const val TAG = "OpenBuilder/FontWeight"
    }
}
