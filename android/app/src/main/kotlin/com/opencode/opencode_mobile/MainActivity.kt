package com.opencode.opencode_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel = "com.opencode.mobile/font_weight"

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
