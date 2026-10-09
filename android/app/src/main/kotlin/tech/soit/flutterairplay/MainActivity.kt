// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.graphics.Color
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.embedding.android.RenderMode
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity(), SurfaceHolder.Callback {
    private lateinit var video: SurfaceView
    private var videoWidth = 0
    private var videoHeight = 0
    var playbackSurface: Surface? = null
        private set

    // Only UI controls are composited by Flutter. Video stays in a separate
    // SurfaceView layer, below the transparent Flutter TextureView.
    override fun getRenderMode(): RenderMode = RenderMode.texture
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val content = findViewById<ViewGroup>(android.R.id.content)
        val flutter = content.getChildAt(0)
        content.removeView(flutter)
        val layers = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        video = SurfaceView(this)
        layers.addView(video, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        layers.addView(flutter, FrameLayout.LayoutParams(-1, -1))
        content.addView(layers, ViewGroup.LayoutParams(-1, -1))
        layers.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> fitVideo() }
        video.holder.addCallback(this)
    }
    internal fun renderVideo(data: Map<String, Any>) {
        videoWidth = (data["videoWidth"] as? Number)?.toInt() ?: 0
        videoHeight = (data["videoHeight"] as? Number)?.toInt() ?: 0
        fitVideo()
    }
    private fun fitVideo() {
        if (!::video.isInitialized || videoWidth <= 0 || videoHeight <= 0) return
        val parent = video.parent as? ViewGroup ?: return
        if (parent.width == 0 || parent.height == 0) return
        val scale = minOf(parent.width.toDouble() / videoWidth, parent.height.toDouble() / videoHeight)
        val width = (videoWidth * scale).toInt().coerceAtLeast(1)
        val height = (videoHeight * scale).toInt().coerceAtLeast(1)
        val params = video.layoutParams as FrameLayout.LayoutParams
        if (params.width == width && params.height == height) return
        params.width = width; params.height = height
        video.layoutParams = params
    }
    override fun surfaceCreated(holder: SurfaceHolder) {
        playbackSurface = holder.surface
        bridge?.nativeSurfaceReady(this)
    }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        playbackSurface = null
        bridge?.nativeSurfaceDestroyed(this)
    }

    private var updateInstaller: AppUpdateInstaller? = null
    private var presentation: MethodChannel? = null
    private var bridge: ReceiverBridge? = null
    override fun provideFlutterEngine(context: Context): FlutterEngine = ReceiverService.engine(context)
    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updateInstaller = AppUpdateInstaller(this, MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "tech.soit.flutterairplay/androidUpdates"))
        bridge = ReceiverService.bridge(this)
        presentation = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tech.soit.flutterairplay/window").also { channel ->
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
                if (call.method != "setPlaybackOrientation") { result.notImplemented(); return@setMethodCallHandler }
                updateOrientation(call.argument<Int>("width") ?: 0,
                    call.argument<Int>("height") ?: 0, call.argument<Boolean>("playing") == true)
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
    override fun onDestroy() {
        bridge?.nativeSurfaceDestroyed(this)
        playbackSurface = null
        updateInstaller?.dispose()
        updateInstaller = null
        presentation?.setMethodCallHandler(null)
        presentation = null
        bridge?.detach(this)
        bridge = null
        super.onDestroy()
    }
}
