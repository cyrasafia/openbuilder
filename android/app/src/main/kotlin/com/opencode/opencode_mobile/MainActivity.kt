package com.opencode.opencode_mobile

import android.content.res.Resources
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
                            // Android 10+ (API 29): Resources.getSystem() exposes
                            // the default Typeface weight via the system's font
                            // configuration. On Xiaomi/HyperOS, the system font
                            // weight slider modifies this.
                            //
                            // Try Settings.System first (Xiaomi stores font
                            // weight here), then fall back to Typeface default.
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
        // Method 1: Check Android Settings for font weight.
        // Xiaomi/HyperOS may store font weight in Settings.System.
        try {
            val weight = android.provider.Settings.System.getInt(
                contentResolver,
                "font_weight",
                -1
            )
            if (weight in 100..900) return weight
        } catch (_: Exception) {}

        // Method 2: Read from Typeface (reflects system font config).
        // Android 12+ Typeface has a weight property on the default font.
        try {
            val typeface = android.graphics.Typeface.DEFAULT
            val field = typeface.javaClass.superclass?.getDeclaredField("weight")
            if (field != null) {
                field.isAccessible = true
                val w = field.getInt(typeface)
                if (w in 100..900) return w
            }
        } catch (_: Exception) {}

        // Method 3: Try Typeface creation with system resources.
        // On some ROMs, the default Typeface reflects the system weight.
        try {
            val res = Resources.getSystem()
            // Check if font_scale or weight is available via configuration
            val config = res.configuration
            // fontScale is for size, not weight, but we check for completeness
            // There's no standard Android API for font weight before Android 12.
        } catch (_: Exception) {}

        return null
    }
}
