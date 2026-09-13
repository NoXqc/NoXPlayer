package com.nox.nox_iptv

import android.app.ActivityManager
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Exposes ActivityManager's real device memory info to Dart — Flutter has
 * no built-in way to ask "how much RAM does this specific device have",
 * and the app's image cache ceiling needs that to scale itself per device
 * instead of using one fixed number for every Firestick regardless of how
 * much headroom it actually has (see main.dart's _configureImageCache).
 * Mirrors how Glide, the standard Android image-loading library, sizes
 * its own cache via ActivityManager.isLowRamDevice()/getMemoryInfo().
 */
class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.nox.nox_iptv/device_memory"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getMemoryInfo") {
                val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val memoryInfo = ActivityManager.MemoryInfo()
                activityManager.getMemoryInfo(memoryInfo)
                result.success(
                    mapOf(
                        "totalMemBytes" to memoryInfo.totalMem,
                        "isLowRamDevice" to activityManager.isLowRamDevice
                    )
                )
            } else {
                result.notImplemented()
            }
        }
    }
}
