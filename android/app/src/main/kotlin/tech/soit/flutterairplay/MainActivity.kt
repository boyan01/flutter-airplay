// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay

import android.content.pm.ActivityInfo
import android.content.res.Configuration
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
import kotlin.math.roundToInt

internal data class VideoPresentation(
    val left: Double = 0.0, val top: Double = 0.0,
    val width: Double = 1.0, val height: Double = 1.0,
    val sourceWidth: Double = 0.0, val sourceHeight: Double = 0.0,
    val viewportLeft: Double = 0.0, val viewportTop: Double = 0.0,
    val viewportWidth: Double = 1.0, val viewportHeight: Double = 1.0,
) {
    companion object {
        fun parse(arguments: Any?): VideoPresentation {
            val values = arguments as? Map<*, *> ?: throw IllegalArgumentException("Expected crop arguments")
            fun number(key: String): Double = (values[key] as? Number)?.toDouble()
                ?.takeIf { it.isFinite() } ?: throw IllegalArgumentException("Invalid $key")
            val left = number("left"); val top = number("top")
            val width = number("width"); val height = number("height")
            require(left >= 0 && left < 1 && top >= 0 && top < 1 && width > 0 && height > 0 &&
                left + width <= 1 + 1e-9 && top + height <= 1 + 1e-9) { "Crop must be within the normalized video frame" }
            val hasSource = values.containsKey("sourceWidth") || values.containsKey("sourceHeight")
            val sourceWidth = if (hasSource) number("sourceWidth") else 0.0
            val sourceHeight = if (hasSource) number("sourceHeight") else 0.0
            require(!hasSource || sourceWidth > 0 && sourceHeight > 0) { "Source dimensions must be positive" }
            val hasViewport = listOf("viewportLeft", "viewportTop", "viewportWidth", "viewportHeight").any { values.containsKey(it) }
            val x = if (hasViewport) number("viewportLeft") else 0.0
            val y = if (hasViewport) number("viewportTop") else 0.0
            val w = if (hasViewport) number("viewportWidth") else 1.0
            val h = if (hasViewport) number("viewportHeight") else 1.0
            require(x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= 1 + 1e-9 && y + h <= 1 + 1e-9) {
                "Viewport must be within the normalized Flutter view"
            }
            return VideoPresentation(left, top, minOf(width, 1 - left), minOf(height, 1 - top), sourceWidth, sourceHeight,
                x, y, minOf(w, 1 - x), minOf(h, 1 - y))
        }
    }
}

class MainActivity : FlutterActivity(), SurfaceHolder.Callback {
    private lateinit var video: SurfaceView
    private lateinit var videoViewport: FrameLayout
    private var videoPresentation = VideoPresentation()
    private var videoWidth = 0
    private var videoHeight = 0
    var playbackSurface: Surface? = null
        private set

    // Only UI controls are composited by Flutter. Video stays in a separate
    // SurfaceView layer, below the transparent Flutter TextureView.
    override fun getRenderMode(): RenderMode = RenderMode.texture
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        savedInstanceState?.getDoubleArray("videoPresentation")?.takeIf { it.size == 6 }?.let {
            videoPresentation = VideoPresentation(it[0], it[1], it[2], it[3], it[4], it[5])
        }
        val content = findViewById<ViewGroup>(android.R.id.content)
        val flutter = content.getChildAt(0)
        content.removeView(flutter)
        val layers = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        videoViewport = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            clipChildren = true
            clipToPadding = true
        }
        video = SurfaceView(this)
        videoViewport.addView(video, FrameLayout.LayoutParams(-1, -1, Gravity.TOP or Gravity.LEFT))
        layers.addView(videoViewport, FrameLayout.LayoutParams(-1, -1, Gravity.TOP or Gravity.LEFT))
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
        if (!::video.isInitialized) return
        val parent = videoViewport.parent as? ViewGroup ?: return
        if (parent.width == 0 || parent.height == 0) return
        val crop = videoPresentation
        val sourceWidth = if (videoWidth > 0 && videoHeight > 0) videoWidth.toDouble() else crop.sourceWidth
        val sourceHeight = if (videoWidth > 0 && videoHeight > 0) videoHeight.toDouble() else crop.sourceHeight
        if (sourceWidth <= 0 || sourceHeight <= 0) return
        val areaWidth = parent.width * crop.viewportWidth
        val areaHeight = parent.height * crop.viewportHeight
        val scale = minOf(areaWidth / (sourceWidth * crop.width), areaHeight / (sourceHeight * crop.height))
        val fullWidth = sourceWidth * scale
        val fullHeight = sourceHeight * scale
        fun update(view: android.view.View, width: Int, height: Int, left: Int = 0, top: Int = 0) {
            val params = view.layoutParams as FrameLayout.LayoutParams
            if (params.width == width && params.height == height && params.leftMargin == left && params.topMargin == top) return
            params.width = width; params.height = height
            params.leftMargin = left; params.topMargin = top
            view.layoutParams = params
        }
        update(videoViewport, (fullWidth * crop.width).roundToInt().coerceAtLeast(1),
            (fullHeight * crop.height).roundToInt().coerceAtLeast(1),
            (parent.width * crop.viewportLeft + (areaWidth - fullWidth * crop.width) / 2).roundToInt(),
            (parent.height * crop.viewportTop + (areaHeight - fullHeight * crop.height) / 2).roundToInt())
        update(video, fullWidth.roundToInt().coerceAtLeast(1), fullHeight.roundToInt().coerceAtLeast(1),
            (-crop.left * fullWidth).roundToInt(), (-crop.top * fullHeight).roundToInt())
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
                if (call.method == "isTelevision") { result.success(isTelevision); return@setMethodCallHandler }
                if (call.method == "setVideoPresentation") {
                    try {
                        videoPresentation = VideoPresentation.parse(call.arguments)
                        fitVideo()
                        result.success(null)
                    } catch (error: IllegalArgumentException) {
                        result.error("invalid_arguments", error.message, null)
                    }
                    return@setMethodCallHandler
                }
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
                updatePlaybackWindow(call.argument<Int>("width") ?: 0,
                    call.argument<Int>("height") ?: 0, call.argument<Boolean>("playing") == true)
                result.success(null)
            }
        }
    }
    private fun updatePlaybackWindow(width: Int, height: Int, playing: Boolean) {
        // Ask the display for its low-latency (game) mode only while mirroring.
        if (Build.VERSION.SDK_INT >= 30) window.setPreferMinimalPostProcessing(playing)
        if (!isTelevision) {
            requestedOrientation = if (!playing) ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                else if (width > height) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                else ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        }
    }
    override fun onSaveInstanceState(outState: Bundle) {
        val crop = videoPresentation
        outState.putDoubleArray("videoPresentation", doubleArrayOf(crop.left, crop.top, crop.width,
            crop.height, crop.sourceWidth, crop.sourceHeight))
        super.onSaveInstanceState(outState)
    }
    override fun onStart() { super.onStart(); bridge?.onForeground(this); fitVideo() }
    override fun onResume() {
        super.onResume()
        bridge?.refresh()
        bridge?.snapshot()?.let {
            val width = (it["videoWidth"] as Number).toInt()
            val height = (it["videoHeight"] as Number).toInt()
            updatePlaybackWindow(width, height, width > 0 && height > 0)
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
