// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var presentation: MethodChannel? = null
    private var bridge: ReceiverBridge? = null
    override fun provideFlutterEngine(context: Context): FlutterEngine = ReceiverService.engine(context)
    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = ReceiverService.bridge(this)
        presentation = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.flutterairplay/window").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "requestBackgroundLaunch" || call.method == "openAppSettings") {
                    try {
                        if (call.method == "openAppSettings") {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName")))
                        } else if (Build.VERSION.SDK_INT >= 29) {
                            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")))
                        }
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("settings", "此设备无法打开系统设置。", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "setMode") { result.notImplemented(); return@setMethodCallHandler }
                updateOrientation(call.argument<Int>("width") ?: 0,
                    call.argument<Int>("height") ?: 0, call.argument<String>("mode") == "player")
                result.success(null)
            }
        }
    }
    private fun updateOrientation(width: Int, height: Int, playing: Boolean) {
        val television = (getSystemService(Context.UI_MODE_SERVICE) as UiModeManager)
            .currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        if (!television) {
            requestedOrientation = if (!playing) ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                else if (width > height) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                else ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        }
    }
    override fun onStart() { super.onStart(); bridge?.onForeground(this) }
    override fun onResume() {
        super.onResume()
        bridge?.refresh()
        bridge?.snapshot()?.let {
            val width = (it["videoWidth"] as Number).toInt()
            val height = (it["videoHeight"] as Number).toInt()
            updateOrientation(width, height, width > 0 && height > 0)
        }
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        bridge?.onDisplayChanged()
    }
    override fun onStop() { bridge?.onBackground(this); super.onStop() }
    override fun onDestroy() { presentation?.setMethodCallHandler(null); presentation = null; bridge?.detach(this);bridge=null;super.onDestroy() }
}
