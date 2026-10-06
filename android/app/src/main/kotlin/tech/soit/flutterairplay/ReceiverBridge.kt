// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay

import android.app.Activity
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.Manifest
import android.os.Build
import android.provider.Settings
import android.content.pm.PackageManager
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Platform bootstrap and Android foreground-service/surface integration. */
internal class ReceiverBridge(private val context: Context, engine: FlutterEngine) : AutoCloseable {
    private val preferences = context.getSharedPreferences("receiver", Context.MODE_PRIVATE)
    private var closed = false
    private var activity: Activity? = null
    private var surfaceOwner: MainActivity? = null
    private val pendingPrepare = mutableListOf<MethodChannel.Result>()
    private var preparing = false
    private var data: Map<String, Any> = mapOf("status" to "stopped", "videoWidth" to 0, "videoHeight" to 0)
    var service: ReceiverService? = null
    private val host = PlaybackHost(context, ::nativeEvent)
    private fun nativeEvent(event: Map<String, Any>) {
        if (!closed && event["type"] == "snapshot") {
            @Suppress("UNCHECKED_CAST")
            val next = event["data"] as Map<String, Any>
            // Discard old stopped snapshots after a replacement run has started.
            val current = host.currentSnapshot
            if ((next["generation"] as? Number)?.toLong() == (current["generation"] as? Number)?.toLong()) {
                data = next
                publish(); lifecycle.reconcile()
            }
        }
    }
    val isActive: Boolean get() = preparing || host.prepared || (data["pid"] as? Number)?.toLong()?.let { it != 0L } == true
    private val lifecycle = ReceiverLifecycle({ isActive }, { if (host.handle != 0L) host.requestStart() })
    private val foreground get() = lifecycle.foreground
    private val control = MethodChannel(engine.dartExecutor.binaryMessenger, "org.airplayreceiver/platform")
    init { control.setMethodCallHandler(::command) }

    private fun defaultName(): String {
        val deviceName = try {
            Settings.Global.getString(context.contentResolver, "device_name")
        } catch (_: SecurityException) { null }
        return deviceName?.takeIf { it.isNotBlank() } ?: Build.MODEL
    }

    fun snapshot(): Map<String, Any> = data
    private fun publish() {
        val caps = data["capabilities"] as? Map<*, *>
        val awake = foreground && (caps?.get("isTelevision") == true || isActive)
        activity?.window?.let { window ->
            if (awake) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        (activity as? MainActivity)?.renderVideo(data); service?.update(data, foreground)
    }
    fun onForeground(activity: Activity) {
        this.activity = activity
        lifecycle.onForeground(data["autoStart"] as? Boolean ?: false)
        host.update(mapOf("foreground" to true)); nativeSurfaceReady(activity as? MainActivity); publish()
    }
    fun onBackground(activity: Activity) {
        if (this.activity !== activity) return
        lifecycle.onBackground(); host.update(mapOf("foreground" to false)); publish()
    }
    fun detach(activity: Activity) { if (this.activity === activity) { onBackground(activity); this.activity = null } }
    fun onDisplayChanged() { host.update(host.videoMetadata()); host.logDisplayInfo(); publish() }
    fun refresh() { publish() }
    private fun command(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "bootstrap" -> {
                    val television = (context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager).currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                    val metadata = mapOf("defaultName" to defaultName(), "foreground" to foreground,
                        "capabilities" to mapOf("platform" to "android", "supportsExecutablePath" to false,
                            "supportsLaunchAtLogin" to false, "isTelevision" to television, "nativeVideoSurface" to true))
                    result.success(mapOf("handle" to host.bootstrap(metadata)))
                }
                "prepareReception" -> {
                    check(foreground || isActive) { "请在应用前台启动接收。" }
                    lifecycle.cancelResume()
                    if (host.prepared && service != null) { result.success(null); return }
                    pendingPrepare.add(result); preparing = true
                    ReceiverService.start(context)
                    if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED && !preferences.getBoolean("notificationRequested", false)) {
                        activity?.let { preferences.edit().putBoolean("notificationRequested", true).apply(); it.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 100) }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            if (call.method == "prepareReception") failPreparation(error.message ?: "Cannot prepare receiver service")
            else result.error("receiver_error", error.message, null)
        }
    }
    private fun failPreparation(message: String) {
        preparing = false; host.cleanupSurface()
        val replies = pendingPrepare.toList(); pendingPrepare.clear()
        replies.forEach { it.error("receiver_error", message, null) }; publish()
    }
    /** Complete preparation only after the foreground notification is posted. */
    fun startPending() {
        if (!preparing) return
        try {
            val owner = activity as? MainActivity; val surface = owner?.playbackSurface?.takeIf { it.isValid }
            host.prepare(surface); surfaceOwner = if (surface != null) owner else null
            val replies = pendingPrepare.toList(); pendingPrepare.clear(); preparing = false
            replies.forEach { it.success(null) }; publish()
        } catch (error: Exception) { failPreparation(error.message ?: "Cannot prepare playback surface") }
    }
    fun nativeSurfaceReady(owner: MainActivity?) {
        if (owner == null || owner !== activity) return
        val surface = owner.playbackSurface ?: return
        if (host.setSurface(surface)) surfaceOwner = owner else stopAfterSurfaceFailure()
    }
    fun nativeSurfaceDestroyed(owner: MainActivity) {
        if (surfaceOwner !== owner) return
        surfaceOwner = null
        if (!host.setSurface(null)) stopAfterSurfaceFailure()
    }
    private fun stopAfterSurfaceFailure() { lifecycle.cancelResume(); host.awaitSurfaceStop(); host.cleanupSurface() }
    fun stop(result: MethodChannel.Result) {
        lifecycle.cancelResume()
        if (preparing) failPreparation("Receiver start has been cancelled")
        host.requestStop(); result.success(null)
    }
    fun onServiceDestroyed(owner: ReceiverService) {
        if (service !== owner) return
        service = null
        if (preparing) return
        lifecycle.cancelResume(); host.requestStop()
    }
    override fun close() {
        closed = true; lifecycle.close(); control.setMethodCallHandler(null)
        pendingPrepare.forEach { it.error("cancelled", "Receiver has closed", null) }; pendingPrepare.clear(); host.close()
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
