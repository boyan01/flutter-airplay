// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.app.UiModeManager
import android.content.Context
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var presentation: MethodChannel? = null
    private var bridge: ReceiverBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = ReceiverBridge(this, flutterEngine)
        presentation = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.flutterairplay/window").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "setMode") { result.notImplemented(); return@setMethodCallHandler }
                val television = (getSystemService(Context.UI_MODE_SERVICE) as UiModeManager)
                    .currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                if (!television) {
                    val playing = call.argument<String>("mode") == "player"
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    requestedOrientation = if (!playing) ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                        else if (width > height) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                        else ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
                }
                result.success(null)
            }
        }
    }
    override fun onStart() { super.onStart(); bridge?.onForeground() }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        bridge?.onDisplayChanged()
    }
    override fun onStop() { bridge?.onBackground(); super.onStop() }
    override fun onDestroy() { presentation?.setMethodCallHandler(null); presentation = null; bridge?.close();bridge=null;super.onDestroy() }
}
