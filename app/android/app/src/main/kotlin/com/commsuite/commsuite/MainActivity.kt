package com.commsuite.commsuite

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "commsuite/updater"
    private val notifyChannelName = "commsuite/notify"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_path", "missing apk path", null)
                            return@setMethodCallHandler
                        }
                        result.success(installApk(path))
                    }
                    "canRequestInstall" -> {
                        result.success(canRequestPackageInstalls())
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notifyChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bringToFront" -> {
                        result.success(bringToFront())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun bringToFront(): Boolean {
        return try {
            val intent = Intent(this, MainActivity::class.java)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK
                        or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                        or Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun canRequestPackageInstalls(): Boolean {
        val pm = packageManager ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            pm.canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun installApk(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false

        // Android 8+ requires the "Install unknown apps" capability; if it is not
        // granted, open the system setting for our package so the user can enable it.
        if (!canRequestPackageInstalls()) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (_: Exception) {
                // ignore; the caller decides what to tell the user
            }
            return false
        }

        val uri: Uri = FileProvider.getUriForFile(
            applicationContext,
            "$packageName.fileprovider",
            file
        )
        return try {
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}