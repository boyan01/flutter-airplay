// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Process
import android.app.Activity
import android.Manifest
import android.os.Build
import android.provider.Settings
import android.content.pm.PackageManager
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Keeps the native receiver and shared Dart API independent of layout/input. */
internal class ReceiverBridge(private val context: Context, engine: FlutterEngine) :
    EventChannel.StreamHandler, AutoCloseable {
    private val preferences = context.getSharedPreferences("receiver", Context.MODE_PRIVATE)
    private val state = ReceiverState()
    private var sink: EventChannel.EventSink? = null
    private var closed = false
    private var activity: Activity? = null
    private var pendingStart: Pair<String, MethodChannel.Result>? = null
    var service: ReceiverService? = null
    val isActive: Boolean get() = host.isActive || pendingStart != null
    private val host = PlaybackHost(context, engine.renderer) { event ->
        if (!closed) { state.accept(event); publish(); reconcileLifecycle() }
    }
    private val lifecycle = ReceiverLifecycle(
        active = { isActive },
        start = ::startForLifecycle,
    )
    private val foreground: Boolean get() = lifecycle.foreground
    private val control = MethodChannel(engine.dartExecutor.binaryMessenger, "org.airplayreceiver/control")
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, "org.airplayreceiver/events")

    init {
        if (preferences.getString("name", null) == null) saveName(defaultName())
        control.setMethodCallHandler(::command)
        events.setStreamHandler(this)
    }

    private fun defaultName(): String {
        val deviceName = try {
            Settings.Global.getString(context.contentResolver, "device_name")
        } catch (_: SecurityException) { null }
        for (candidate in listOf(deviceName, Build.MODEL, "Flutter AirPlay")) {
            val clean = StringBuilder()
            var bytes = 0
            val source = candidate?.trim().orEmpty()
            var index = 0
            while (index < source.length) {
                val codePoint = source.codePointAt(index)
                index += Character.charCount(codePoint)
                if (Character.isISOControl(codePoint)) continue
                val character = String(Character.toChars(codePoint))
                val size = character.toByteArray(Charsets.UTF_8).size
                if (bytes + size > 50) break
                clean.append(character)
                bytes += size
            }
            if (clean.isNotBlank()) return clean.toString().trim()
        }
        return "Flutter AirPlay"
    }

    private fun name(): String = preferences.getString("name", "Flutter AirPlay")!!

    fun snapshot(): Map<String, Any> {
        val television = (context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager)
            .currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        return state.snapshot(name(), if (isActive) Process.myPid() else 0, television) +
            mapOf("autoStart" to preferences.getBoolean("autoStart", true))
    }

    private fun publish() {
        val data = snapshot()
        val television = (data["capabilities"] as Map<*, *>)["isTelevision"] == true
        val awake = foreground && (television || isActive)
        activity?.window?.let { window ->
            if (awake) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        sink?.success(mapOf("type" to "snapshot", "data" to data))
        service?.update(data, foreground)
    }

    fun onForeground(activity: Activity) {
        this.activity = activity
        lifecycle.onForeground(preferences.getBoolean("autoStart", true))
        publish()
    }

    fun onBackground(activity: Activity) {
        if (this.activity !== activity) return
        lifecycle.onBackground(); publish()
    }

    fun detach(activity: Activity) {
        if (this.activity !== activity) return
        onBackground(activity)
        this.activity = null
    }

    fun onDisplayChanged() { if (host.isActive) host.logDisplayInfo() }
    fun refresh() { publish() }

    private fun reconcileLifecycle() { if (!closed) lifecycle.reconcile() }

    private fun startForLifecycle() {
        if (closed) return
        try {
            checkPlayback()
            requestStart(name(), object : MethodChannel.Result {
                override fun success(value: Any?) {}
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        } catch (error: Exception) { state.error(error.message ?: "启动接收失败"); publish() }
    }

    private fun requestStart(name: String, result: MethodChannel.Result) {
        state.startRequested()
        pendingStart = name to result
        try {
            ReceiverService.start(context)
        } catch (error: Exception) {
            pendingStart = null
            state.error(error.message ?: "启动后台接收失败")
            publish()
            result.error("service", error.message, null)
            return
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !preferences.getBoolean("notificationRequested", false)) {
            activity?.let {
                preferences.edit().putBoolean("notificationRequested", true).apply()
                it.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 100)
            }
        }
        publish()
    }

    /** Called only after the Service has posted its foreground notification. */
    fun startPending() {
        val request = pendingStart ?: return
        pendingStart = null
        host.start(request.first, completion(request.second, starting = true))
        publish()
    }

    fun stop(result: MethodChannel.Result) {
        lifecycle.cancelResume()
        pendingStart?.second?.error("cancelled", "接收启动已取消", null)
        pendingStart = null
        if (!host.isActive) {
            state.accept(mapOf("state" to "stopped", "message" to "接收器已停止"))
            publish()
            result.success(null)
            return
        }
        state.stopRequested()
        host.stop(completion(result, starting = false))
        publish()
    }

    fun onServiceDestroyed(owner: ReceiverService) {
        if (service !== owner) return
        service = null
        // Dart can queue a replacement start before the stopped Service is
        // destroyed. The replacement Service must retain that pending request.
        if (pendingStart != null) return
        lifecycle.cancelResume()
        if (host.isActive) {
            state.stopRequested()
            host.stop(completion(object : MethodChannel.Result {
                override fun success(value: Any?) {}
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            }, starting = false))
        }
        publish()
    }

    private fun command(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "snapshot" -> result.success(snapshot())
                "save" -> {
                    requireEmbeddedPath(call)
                    val nextName = requestedName(call)
                    check(!isActive || nextName == name()) { "请等待接收器停止后再修改设备名。" }
                    saveName(nextName)
                    call.argument<Boolean>("autoStart")?.let {
                        preferences.edit().putBoolean("autoStart", it).apply()
                    }
                    // Root ReceiverModel updates its editable fields after save succeeds.
                    result.success(null)
                }
                "check" -> {
                    requireIdle()
                    requireEmbeddedPath(call)
                    checkPlayback()
                    state.log("内置接收库已加载；设备提供 H.264 / AAC 解码器。实际播放需连接发送端验证。")
                    publish()
                    result.success(null)
                }
                "start" -> {
                    check(foreground) { "请在应用前台启动接收。" }
                    lifecycle.cancelResume()
                    requireIdle()
                    requireEmbeddedPath(call)
                    val name = requestedName(call)
                    checkPlayback()
                    saveName(name)
                    requestStart(name, result)
                }
                "stop" -> {
                    stop(result)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("receiver_error", error.message ?: "原生接收器操作失败", null)
        }
    }

    private fun completion(result: MethodChannel.Result, starting: Boolean) = object : MethodChannel.Result {
        override fun success(value: Any?) {
            if (closed) return
            if (starting) state.started(value as Map<*, *>)
            publish()
            result.success(null)
            reconcileLifecycle()
        }
        override fun error(code: String, message: String?, details: Any?) {
            if (closed) return
            if (code != "cancelled") state.error(message ?: "原生接收器操作失败")
            publish()
            result.error(code, message, details)
        }
        override fun notImplemented() { if (!closed) result.notImplemented() }
    }

    private fun requireIdle() { check(!isActive) { "请先停止接收器再修改设置或重新启动。" } }
    private fun requireEmbeddedPath(call: MethodCall) {
        require(call.argument<String>("path").orEmpty().isBlank()) {
            "Android 使用内置接收核心，无需填写 UxPlay 路径。"
        }
    }
    private fun requestedName(call: MethodCall): String {
        val value = call.argument<String>("name").orEmpty().trim()
        require(ReceiverState.validName(value)) { "设备名需要 1–50 个 UTF-8 字节，不能含控制字符。" }
        return value
    }
    private fun saveName(value: String) { preferences.edit().putString("name", value).apply() }

    private fun checkPlayback() {
        // Enumeration only: no codec allocation, listener, audio stream or volume changes.
        val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder }
        for (mime in listOf(MediaFormat.MIMETYPE_VIDEO_AVC, MediaFormat.MIMETYPE_AUDIO_AAC)) {
            check(decoders.any { codec -> codec.supportedTypes.any { it.equals(mime, ignoreCase = true) } }) {
                "设备缺少 $mime 解码器，请使用支持 H.264 / AAC 的 Android 设备。"
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events; publish() }
    override fun onCancel(arguments: Any?) { sink = null }
    override fun close() {
        closed = true
        lifecycle.close()
        control.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        host.close()
    }
}

/** Backgrounding leaves the Service running; only foreground entry may auto-start. */
internal class ReceiverLifecycle(
    private val active: () -> Boolean,
    private val start: () -> Unit,
) {
    var foreground = false
        private set
    private var resumePending = false
    private var closed = false
    fun onForeground(autoStart: Boolean) {
        foreground = true; resumePending = autoStart; reconcile()
    }
    fun onBackground() {
        foreground = false
    }
    fun cancelResume() { resumePending = false }
    fun close() { closed = true; resumePending = false }
    fun reconcile() {
        if (closed) return
        if (foreground && resumePending && !active()) {
            resumePending = false; start()
        }
    }
}
