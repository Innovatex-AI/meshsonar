package com.meshsonar.app

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Not compiled on the build Mac (no Android toolchain, Android work on hold). Written to compile in principle.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.meshsonar/alerts").setMethodCallHandler { call, result ->
            when (call.method) {
                // lib/platform/local_notifications_plugin.dart: "Open settings" when notifications are blocked.
                "openNotificationSettings" -> {
                    val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(i)
                    result.success(null)
                }
                // Badge counts are an iOS notion; Android derives them from active notifications.
                "setBadge" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }
}
