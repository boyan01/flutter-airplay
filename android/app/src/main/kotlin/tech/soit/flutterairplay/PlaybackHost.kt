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
import io.flutter.plugin.common.MethodChannel
import tech.soit.flutterairplay.renderer.DecoderSelector
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.Executors

/** Owns one receiver, playback surface and its two discovery registrations. */
class PlaybackHost(private val context: Context,
                   private val emit: (Map<String, Any>) -> Unit) {
    companion object { init { System.loadLibrary("airplay_player") } }
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val registrations = mutableListOf<Registration>()
    private var surface: Surface? = null
    private var backgroundSurface: BackgroundSurface? = null
    private var multicast: WifiManager.MulticastLock? = null
    private var pendingStart: MethodChannel.Result? = null
    private var busy = false
    private var running = false
    var activeSettings: Map<String, Any> = emptyMap()
        private set
    val receivingName: String? get() = registrations.firstOrNull()?.info?.serviceName
    private var generation = 0
    private var frames = 0L
    private var decodedWidth = 0
    private var decodedHeight = 0
    // Accessed by the bridge only on the Android main thread. A live JNI host
    // must remain stoppable even if its decoder reports an error.
    val isActive: Boolean get() = busy || running
    private fun send(message: String, state: String = "waiting", epoch: Int = generation) {
        main.post { if (epoch == generation) emit(mapOf("state" to state, "message" to message)) }
    }
    private fun diagnostic(message: String) {
        Log.i("AirPlayPlayback", message)
        main.post { emit(mapOf("log" to message)) }
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
    private val videoDecoder by lazy { DecoderSelector().avc() }
    private fun supportsVideoSize(width: Int, height: Int): Boolean = runCatching {
        videoDecoder?.getCapabilitiesForType(DecoderSelector.AVC)?.videoCapabilities
            ?.areSizeAndRateSupported(width, height, 60.0) == true
    }.getOrDefault(false)

    private val videoQualities by lazy {
        VideoQuality.presets.filter { it == "auto" || VideoQuality.supported(it.toInt(), ::supportsVideoSize) }
    }

    fun videoSettings(): Map<String, Any> {
        val mode = (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager)
            .getDisplay(Display.DEFAULT_DISPLAY)?.mode
        val metrics = context.resources.displayMetrics
        return mapOf(
            "buildTime" to BuildConfig.BUILD_TIME,
            "fastPairing" to context.getSharedPreferences("receiver", Context.MODE_PRIVATE)
                .getBoolean("fastPairing", false),
            "audioOutput" to context.getSharedPreferences("receiver", Context.MODE_PRIVATE)
                .getString("audioOutput", "auto")!!,
            "videoQuality" to context.getSharedPreferences("receiver", Context.MODE_PRIVATE)
                .getString("videoQuality", "auto")!!,
            "screenWidth" to (mode?.physicalWidth ?: metrics.widthPixels),
            "screenHeight" to (mode?.physicalHeight ?: metrics.heightPixels),
            "videoQualities" to videoQualities,
        )
    }

    fun validateVideoQuality(value: String) {
        val settings = videoSettings()
        VideoQuality.height(value, settings["screenHeight"] as Int, ::supportsVideoSize)
    }

    fun start(requestedName: String, result: MethodChannel.Result, nativeSurface: Surface?) {
        if (busy || running) { result.error("busy", "接收器已启动或正在操作", null); return }
        val name = requestedName.trim()
        if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > 50 ||
            name.any { it.code < 32 || it.code == 127 }) {
            result.error("name", "设备名需要 1–50 个 UTF-8 字节，不能含控制字符", null); return
        }
        val settings = videoSettings()
        val requestHeight: Int
        try {
            requestHeight = VideoQuality.height(settings["videoQuality"] as String,
                settings["screenHeight"] as Int, ::supportsVideoSize)
        } catch (error: Exception) {
            result.error("video_quality", error.message, null); return
        }
        val requestWidth = VideoQuality.width(requestHeight)
        activeSettings = mapOf("name" to name, "path" to "",
            "videoQuality" to settings["videoQuality"]!!,
            "audioOutput" to settings["audioOutput"]!!,
            "fastPairing" to settings["fastPairing"]!!)
        pendingStart = result
        busy = true
        val epoch = ++generation
        frames = 0
        try {
            logDisplayInfo()
            logAudioSystemInfo()
            diagnostic("Audio output selection: ${settings["audioOutput"]}; applies for this receiver run")
            diagnostic("Receiver request: quality=${settings["videoQuality"]}, ${requestWidth}x${requestHeight}, maxFPS=60; sender chooses actual codec/size/rate")
            diagnostic("Video output: native SurfaceView")
            backgroundSurface = BackgroundSurface()
            surface = nativeSurface ?: backgroundSurface!!.surface
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicast = wifi.createMulticastLock("FlutterAirPlayDiscovery").also { it.setReferenceCounted(false); it.acquire() }
        } catch (e: Exception) {
            cleanupSurface(); busy=false
            pendingStart = null
            result.error("playback", e.message, null);return
        }
        send("正在启动接收器", "starting")
        worker.execute {
            try {
                val selector = DecoderSelector().also { it.onDiagnostic = ::diagnostic }
                val decoder = videoDecoder?.name ?: error("No H.264 decoder available")
                val fallback = selector.software(DecoderSelector.AVC, VideoQuality.decoderWidth(requestHeight), (requestHeight + 15) / 16 * 16)?.name ?: ""
                val hevc = selector.hevc(VideoQuality.decoderWidth(requestHeight), (requestHeight + 15) / 16 * 16)?.name ?: ""
                diagnostic("HEVC receiver capability: ${if (hevc.isEmpty()) "unavailable for this size/rate" else hevc}")
                val prefs=context.getSharedPreferences("receiver", Context.MODE_PRIVATE)
                val hex=prefs.getString("identity",null) ?: ByteArray(6).also {
                    SecureRandom().nextBytes(it); it[0]=((it[0].toInt() or 2) and 254).toByte()
                }.joinToString("") { "%02X".format(it.toInt() and 255) }.also {
                    prefs.edit().putString("identity",it).apply()
                }
                val identity=hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
                val port=startNative(name,identity,File(context.filesDir,"airplay-pairing.pem").absolutePath,
                    surface!!, decoder, fallback, hevc, epoch, requestWidth, requestHeight,
                    when (settings["audioOutput"]) { "aaudio" -> 1; "audiotrack" -> 2; else -> 0 },
                    settings["fastPairing"] as Boolean)
                val videoTxt=parseTxt(txtNative(false)); val audioTxt=parseTxt(txtNative(true))
                main.post {
                    if(epoch!=generation) return@post
                    running=true
                    val done= { if(registrations.size==2 && registrations.all { it.registered }) {
                        busy=false
                        send("在 iPhone 屏幕镜像中选择「${registrations[0].info.serviceName}」", "ready")
                    } }
                    try {
                        register(name,"_airplay._tcp",port,videoTxt,epoch,done)
                        register("${hex.uppercase()}@$name","_raop._tcp",port,audioTxt,epoch,done)
                        pendingStart = null
                        result.success(mapOf("textureId" to -1L, "width" to 1920,"height" to 1080, "name" to name))
                    } catch(e:Exception) {
                        busy=false
                        pendingStart = null
                        result.error("discovery", e.message,null)
                        stopInternal(null)
                    }
                }
            } catch (e: Exception) {
                stopNative()
                main.post { if(epoch==generation) { cleanupSurface();busy=false;pendingStart=null;send(e.message?:"启动失败","error");result.error("start",e.message,null) } }
            }
        }
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
    private fun register(name:String,type:String,port:Int,txt:Map<String,ByteArray>,epoch:Int,done:()->Unit) {
        val info=NsdServiceInfo().apply {
            serviceName=name;serviceType=type;setPort(port)
            txt.forEach { (k,v)->setAttribute(k,String(v,Charsets.UTF_8)) }
        }
        val registration=Registration(info,epoch,done)
        registrations.add(registration)
        nsd.registerService(info,NsdManager.PROTOCOL_DNS_SD,registration)
    }
    private inner class Registration(var info:NsdServiceInfo,val epoch:Int,val done:()->Unit):NsdManager.RegistrationListener {
        var registered=false;var cancelled=false
        private fun unregister() { try { nsd.unregisterService(this) } catch (_:Exception) {} }
        fun cancel() { cancelled=true;if(registered)unregister() }
        override fun onServiceRegistered(value:NsdServiceInfo) { main.post {
            registered=true;info=value
            if(cancelled || epoch!=generation)unregister() else done()
        } }
        override fun onRegistrationFailed(value:NsdServiceInfo,code:Int) { main.post {
            if(!cancelled && epoch==generation) { send("设备发现失败 ($code)，请停止后重试","error");stopInternal(null) }
        } }
        override fun onServiceUnregistered(value:NsdServiceInfo) { registered=false }
        override fun onUnregistrationFailed(value:NsdServiceInfo,code:Int) { main.post {
            diagnostic("设备发现注销失败 ($code)")
        } }
    }
    fun prepareRestart(): Boolean = worker.submit<Boolean> { prepareRestartNative() }.get()
    private external fun prepareRestartNative(): Boolean

    fun stop(result:MethodChannel.Result) {
        stopInternal(result)
    }
    private fun stopInternal(result:MethodChannel.Result?) {
        pendingStart?.error("cancelled", "接收启动已取消", null)
        pendingStart = null
        ++generation;busy=true;running=false
        registrations.forEach { it.cancel() };registrations.clear()
        worker.execute {
            stopNative()
            main.post { cleanupSurface();busy=false;send("接收器已停止","stopped");result?.success(null) }
        }
    }
    // SurfaceHolder requires all rendering to stop before surfaceDestroyed returns.
    // Native shutdown runs on the same serialized worker and never waits on main.
    fun setSurface(visible: Surface?): Boolean {
        if (!isActive) return true
        val target = visible ?: backgroundSurface?.surface ?: return true
        val changed = worker.submit<Boolean> { setSurfaceNative(target) }.get()
        diagnostic("Video surface: ${if (visible == null) "background" else "visible"}, switched=$changed")
        return changed
    }
    fun awaitSurfaceStop() { worker.submit { stopNative() }.get() }
    private fun cleanupSurface() {
        // SurfaceHolder owns this surface; native shutdown releases its window reference.
        surface=null
        backgroundSurface?.close();backgroundSurface=null
        multicast?.let { if(it.isHeld)it.release() };multicast=null
    }
    fun close() { stopInternal(null); worker.shutdown() }
    // Epochs are immutable in JNI and checked after dispatch to the main thread.
    fun onNativeLog(epoch: Int, level: Int, bytes: ByteArray) {
        val text = bytes.toString(Charsets.UTF_8)
        main.post { if (epoch == generation) diagnostic("[Native level=$level] $text") }
    }
    fun onNativeEvent(epoch: Int, type: String, bytes: ByteArray, width: Int, height: Int) {
        val detail = bytes.toString(Charsets.UTF_8)
        main.post {
            if (epoch != generation) return@post
            when (type) {
                "audio", "audio_stopped", "paused", "reset", "error" -> {
                    diagnostic("[Native event=$type] $detail")
                    if (type == "audio") logAudioSystemInfo()
                }
            }
            when (type) {
                "client" -> emit(mapOf("clientName" to detail, "state" to "connecting"))
                "connecting" -> send("已建立连接，等待第一帧画面", "connecting")
                "playing" -> {
                    if (frames == 0L || width != decodedWidth || height != decodedHeight) {
                        decodedWidth = width; decodedHeight = height
                        emit(mapOf("width" to width, "height" to height))
                    }
                    if (frames++ == 0L) send("正在播放屏幕镜像", "playing")
                }
                "paused", "reset" -> { frames = 0; emit(mapOf("width" to 0, "height" to 0, "state" to type)) }
                "audio", "audio_stopped" -> emit(mapOf("state" to type))
                "waiting" -> send("等待 iPhone 屏幕镜像", "waiting")
                "error" -> { frames = 0; send(detail, "error") }
            }
        }
    }
    private external fun startNative(name: String, identity: ByteArray, keyPath: String,
                                     surface: Surface, decoder: String, fallback: String, hevcDecoder: String, epoch: Int, width: Int, height: Int, audioMode: Int, fastPairing: Boolean): Int
    private external fun txtNative(raop: Boolean): ByteArray
    private external fun setSurfaceNative(surface: Surface): Boolean
    private external fun stopNative()
}
