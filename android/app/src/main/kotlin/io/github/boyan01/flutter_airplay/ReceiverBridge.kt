// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Process
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
    private val host = PlaybackHost(context, engine.renderer) { event ->
        if (!closed) { state.accept(event); publish() }
    }
    private val control = MethodChannel(engine.dartExecutor.binaryMessenger, "org.airplayreceiver/control")
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, "org.airplayreceiver/events")

    init {
        control.setMethodCallHandler(::command)
        events.setStreamHandler(this)
    }

    private fun name(): String = preferences.getString("name", "Flutter AirPlay Android")!!

    private fun snapshot(): Map<String, Any> {
        val television = (context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager)
            .currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        return state.snapshot(name(), if (host.isActive) Process.myPid() else 0, television)
    }

    private fun publish() { sink?.success(mapOf("type" to "snapshot", "data" to snapshot())) }

    private fun command(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "snapshot" -> result.success(snapshot())
                "save" -> {
                    requireIdle()
                    requireEmbeddedPath(call)
                    saveName(requestedName(call))
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
                    requireIdle()
                    requireEmbeddedPath(call)
                    val name = requestedName(call)
                    checkPlayback()
                    saveName(name)
                    state.startRequested()
                    // PlaybackHost sets its active flag before any event is dispatched.
                    host.start(name, completion(result, starting = true))
                    publish()
                }
                "stop" -> {
                    if (!host.isActive) { result.success(null); return }
                    state.stopRequested()
                    host.stop(completion(result, starting = false))
                    publish()
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
        }
        override fun error(code: String, message: String?, details: Any?) {
            if (closed) return
            state.error(message ?: "原生接收器操作失败")
            publish()
            result.error(code, message, details)
        }
        override fun notImplemented() { if (!closed) result.notImplemented() }
    }

    private fun requireIdle() { check(!host.isActive) { "请先停止接收器再修改设置或重新启动。" } }
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
        control.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        host.close()
    }
}
