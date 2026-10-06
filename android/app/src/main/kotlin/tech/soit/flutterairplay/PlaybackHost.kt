// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay

import android.media.AudioManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.hardware.display.DisplayManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.util.Log
import android.view.Display
import android.view.Surface
import tech.soit.flutterairplay.renderer.DecoderSelector
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.security.SecureRandom

/** Android surfaces/codecs/discovery only; commands and state live in C++. */
class PlaybackHost(private val context: Context, private val emit: (Map<String, Any>) -> Unit) {
    companion object { init { System.loadLibrary("airplay_player") } }
    private val main = Handler(Looper.getMainLooper())
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val registrations = mutableListOf<Registration>()
    @Volatile private var backgroundSurface: BackgroundSurface? = null
    private var multicast: WifiManager.MulticastLock? = null
    @Volatile private var generation = 0L
    private var closed = false
    private val resourcesLock = Any()
    @Volatile var currentSnapshot: Map<String, Any> = emptyMap()
        private set
    var handle = 0L
        private set
    val prepared get() = backgroundSurface != null
    private fun diagnostic(message: String) {
        Log.i("AirPlayPlayback", message)
        if (handle != 0L) logNative(handle, message)
    }
    fun bootstrap(metadata: Map<String, Any>): Long {
        check(!closed) { "Native host has closed" }; if (handle != 0L) return handle
        val prefs = context.getSharedPreferences("receiver", Context.MODE_PRIVATE)
        val hex = prefs.getString("identity", null) ?: ByteArray(6).also {
            SecureRandom().nextBytes(it); it[0] = ((it[0].toInt() or 2) and 254).toByte()
        }.joinToString("") { "%02X".format(it.toInt() and 255) }.also { prefs.edit().putString("identity", it).apply() }
        val identity = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        handle = createNative(JSONObject(metadata + videoMetadata()).toString(), identity,
            File(context.filesDir, "airplay-pairing.pem").absolutePath)
        check(handle != 0L) { "Cannot create native receiver" }; return handle
    }
    fun requestStart() { if (handle != 0L && !closed) requestStartNative(handle) }
    fun requestStop() { if (handle != 0L && !closed) requestStopNative(handle) }
    private fun objectMap(value: JSONObject): Map<String, Any> = value.keys().asSequence().associateWith {
        when (val item = value.get(it)) {
            is JSONObject -> objectMap(item)
            is JSONArray -> (0 until item.length()).map { i -> item.get(i) }
            else -> item
        }
    }
    fun update(metadata: Map<String, Any>) { if (handle != 0L) updateNative(handle, JSONObject(metadata).toString()) }
    fun prepare(visible: Surface?) {
        synchronized(resourcesLock) {
        if (backgroundSurface == null) {
            backgroundSurface = BackgroundSurface()
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicast = wifi.createMulticastLock("FlutterAirPlayDiscovery").also { it.setReferenceCounted(false); it.acquire() }
        }
        }
        check(setSurface(visible)) { "Cannot prepare Android playback surface" }
        logDisplayInfo(); logAudioSystemInfo()
    }
    fun setSurface(visible: Surface?): Boolean {
        if (!prepared || handle == 0L) return true
        val target = visible ?: backgroundSurface!!.surface
        return setSurfaceNative(handle, target)
    }
    fun awaitSurfaceStop() { if (handle != 0L) stopNative(handle) }
    fun cleanupSurface() { endVideo(false) }
    fun endVideo(restarting: Boolean) {
        if (restarting) return
        synchronized(resourcesLock) {
        backgroundSurface?.close(); backgroundSurface = null
        multicast?.let { if (it.isHeld) it.release() }; multicast = null
        }
    }
    private val videoDecoder by lazy { DecoderSelector().avc() }
    private fun supportsVideoSize(width: Int, height: Int): Boolean = runCatching {
        videoDecoder?.getCapabilitiesForType(DecoderSelector.AVC)?.videoCapabilities
            ?.areSizeAndRateSupported(width, height, 60.0) == true
    }.getOrDefault(false)
    fun videoMetadata(): Map<String, Any> {
        val mode = (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).getDisplay(Display.DEFAULT_DISPLAY)?.mode
        val metrics = context.resources.displayMetrics
        val height = mode?.physicalHeight ?: metrics.heightPixels
        return mapOf("buildTime" to BuildConfig.BUILD_TIME,
            "screenWidth" to (mode?.physicalWidth ?: metrics.widthPixels), "screenHeight" to height,
            "autoVideoHeight" to VideoQuality.height("auto", height, ::supportsVideoSize),
            "videoQualities" to VideoQuality.presets.filter { it == "auto" || VideoQuality.supported(it.toInt(), ::supportsVideoSize) })
    }
    // Invoked on the shared native worker; never waits for Android main.
    fun selectDecoders(width: Int, height: Int): Array<String> {
        val selector = DecoderSelector().also { it.onDiagnostic = ::diagnostic }
        val wide = VideoQuality.decoderWidth(height); val high = (height + 15) / 16 * 16
        return arrayOf(videoDecoder?.name ?: error("No H.264 decoder available"),
            selector.software(DecoderSelector.AVC, wide, high)?.name ?: "", selector.hevc(wide, high)?.name ?: "")
    }
    fun onNativeEvent(bytes: ByteArray) {
        val event = objectMap(JSONObject(bytes.toString(Charsets.UTF_8)))
        if (event["type"] == "snapshot") {
            @Suppress("UNCHECKED_CAST")
            val snapshot = event["data"] as Map<String, Any>
            currentSnapshot = snapshot
        }
        main.post { if (!closed) emit(event) }
    }
    fun publishNative(epoch: Long, label: ByteArray, identity: ByteArray, port: Int, video: ByteArray, audio: ByteArray) {
        generation = epoch
        val name = label.toString(Charsets.UTF_8); val hex = identity.joinToString("") { "%02X".format(it.toInt() and 255) }
        main.post {
            if (closed || epoch != generation) return@post
            try {
                val done = {
                    if (registrations.size == 2 && registrations.all { it.registered })
                        discoveryNative(handle, epoch, true, "", registrations[0].info.serviceName)
                }
                register(name, "_airplay._tcp", port, parseTxt(video), epoch, done)
                register("$hex@$name", "_raop._tcp", port, parseTxt(audio), epoch, done)
            } catch (error: Exception) { discoveryNative(handle, epoch, false, error.message ?: "Discovery failed", "") }
        }
    }
    fun unpublishNative() {
        ++generation
        main.post { registrations.forEach { it.cancel() }; registrations.clear() }
    }
    fun logDisplayInfo() {
        val display = (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager)
            .getDisplay(Display.DEFAULT_DISPLAY)
        val metrics = context.resources.displayMetrics
        val mode = display?.mode
        val debug = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        diagnostic("Display: model=${Build.MODEL}, API=${Build.VERSION.SDK_INT}, " +
            "build=${if (debug) "debug" else "release"}, " +
            "physical=${mode?.physicalWidth}x${mode?.physicalHeight}, " +
            "app=${metrics.widthPixels}x${metrics.heightPixels}, density=${metrics.density}, " +
            "refreshHz=${display?.refreshRate}, rotation=${display?.rotation}")
        diagnostic("Display modes: ${display?.supportedModes?.joinToString { "${it.modeId}:${it.physicalWidth}x${it.physicalHeight}@${it.refreshRate}" }}")
        diagnostic("Build: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) ${BuildConfig.BUILD_TIME}")
    }
    private fun logAudioSystemInfo() {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        runCatching {
            val devices = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .joinToString { "id=${it.id}/type=${it.type}" }
            diagnostic("Android media audio: volume=${audio.getStreamVolume(AudioManager.STREAM_MUSIC)}/" +
                "${audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)}, " +
                "muted=${audio.isStreamMute(AudioManager.STREAM_MUSIC)}, mode=${audio.mode}, " +
                "availableOutputs=[$devices]")
        }.onFailure { diagnostic("Android media audio query failed: ${it.javaClass.simpleName}") }
    }
    private fun parseTxt(data:ByteArray):Map<String,ByteArray> {
        val items=linkedMapOf<String,ByteArray>();var i=0
        while(i<data.size) {
            val length=data[i++].toInt() and 255
            require(i+length<=data.size)
            val item=data.copyOfRange(i,i+length);i+=length
            val split=item.indexOf('='.code.toByte())
            if(split>0)items[String(item,0,split,Charsets.US_ASCII)]=item.copyOfRange(split+1,item.size)
        }
        return items
    }
    private fun register(name:String,type:String,port:Int,txt:Map<String,ByteArray>,epoch:Long,done:()->Unit) {
        val info=NsdServiceInfo().apply {
            serviceName=name;serviceType=type;setPort(port)
            txt.forEach { (k,v)->setAttribute(k,String(v,Charsets.UTF_8)) }
        }
        val registration=Registration(info,epoch,done)
        registrations.add(registration)
        nsd.registerService(info,NsdManager.PROTOCOL_DNS_SD,registration)
    }
    private inner class Registration(var info:NsdServiceInfo,val epoch:Long,val done:()->Unit):NsdManager.RegistrationListener {
        var registered=false;var cancelled=false
        private fun unregister() { try { nsd.unregisterService(this) } catch (_:Exception) {} }
        fun cancel() { cancelled=true;if(registered)unregister() }
        override fun onServiceRegistered(value:NsdServiceInfo) { main.post {
            registered=true;info=value
            if(cancelled || epoch!=generation)unregister() else done()
        } }
        override fun onRegistrationFailed(value:NsdServiceInfo,code:Int) { main.post {
            if(!cancelled && epoch==generation) { discoveryNative(handle, epoch, false, "Discovery registration failed ($code)", "") }
        } }
        override fun onServiceUnregistered(value:NsdServiceInfo) { registered=false }
        override fun onUnregistrationFailed(value:NsdServiceInfo,code:Int) { main.post {
            diagnostic("设备发现注销失败 ($code)")
        } }
    }
    fun close() {
        closed = true; ++generation
        registrations.forEach { it.cancel() }; registrations.clear()
        disposeNative(handle); handle = 0L; cleanupSurface()
    }
    private external fun createNative(metadata: String, identity: ByteArray, key: String): Long
    private external fun stopNative(handle: Long)
    private external fun requestStartNative(handle: Long)
    private external fun requestStopNative(handle: Long)
    private external fun logNative(handle: Long, message: String)
    private external fun discoveryNative(handle: Long, epoch: Long, ready: Boolean, error: String, name: String)
    private external fun updateNative(handle: Long, metadata: String)
    private external fun setSurfaceNative(handle: Long, surface: Surface?): Boolean
    private external fun disposeNative(handle: Long)
}
