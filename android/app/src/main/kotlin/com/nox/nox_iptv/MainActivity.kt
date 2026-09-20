package com.nox.nox_iptv

import android.app.ActivityManager
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Exposes ActivityManager's real device memory info to Dart — Flutter has
 * no built-in way to ask "how much RAM does this specific device have",
 * and the app's image cache ceiling needs that to scale itself per device
 * instead of using one fixed number for every Firestick regardless of how
 * much headroom it actually has (see main.dart's _configureImageCache).
 * Mirrors how Glide, the standard Android image-loading library, sizes
 * its own cache via ActivityManager.isLowRamDevice()/getMemoryInfo().
 *
 * Also exposes the "install a downloaded update APK" flow for
 * AppUpdateService's in-app "Check for Updates" — no Flutter plugin
 * covers this on its own, since it involves both a permission check only
 * meaningful on Android 8+ and handing another app (the system installer)
 * a content:// URI via FileProvider, which needs the provider declared in
 * AndroidManifest.xml/res/xml/file_paths.xml.
 */
class MainActivity : FlutterActivity() {
    private val MEMORY_CHANNEL = "com.nox.nox_iptv/device_memory"
    private val UPDATE_CHANNEL = "com.nox.nox_iptv/app_update"
    private val DEVICE_CHANNEL = "com.nox.nox_iptv/device_type"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEMORY_CHANNEL).setMethodCallHandler { call, result ->
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

        // Is this actually a television? Asked because the previous
        // "auto" layout heuristic compared MediaQuery width against a
        // fixed logical-pixel threshold, and a 1080p TV running at 2x
        // density reports 960dp — under the threshold — so every Android
        // TV box and Fire Stick silently got the phone layout on first
        // launch. Screen size cannot distinguish a TV from a tablet;
        // Android's own UI mode can.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isTelevision") {
                val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                val isTvUiMode = uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                // Leanback is what a TV launcher requires of an app, and is
                // present on Fire TV even where the UI mode is reported
                // inconsistently, so either signal is enough.
                val hasLeanback =
                    packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                        packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION)
                result.success(isTvUiMode || hasLeanback)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "canRequestInstalls" -> {
                    // Only a real gate on Android 8 (API 26)+ — earlier
                    // versions have no per-app "unknown sources" toggle at
                    // all, installing from any source just works.
                    val canInstall = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(canInstall)
                }
                "requestInstallPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val intent = Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                        intent.data = Uri.parse("package:$packageName")
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                    }
                    result.success(null)
                }
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("NO_PATH", "filePath argument missing", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(filePath)
                        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("INSTALL_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
