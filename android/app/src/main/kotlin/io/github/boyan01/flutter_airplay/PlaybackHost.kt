// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

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
import io.flutter.view.TextureRegistry
import io.github.jqssun.airplay.renderer.VideoRenderer
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.Executors

/** Owns one receiver, playback surface and its two discovery registrations. */
class PlaybackHost(private val context: Context, private val textures: TextureRegistry,
                   private val emit: (Map<String, Any>) -> Unit) {
    companion object { init { System.loadLibrary("airplay_player") } }
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val registrations = mutableListOf<Registration>()
    private var texture: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    @Volatile private var renderer: VideoRenderer? = null
    private var multicast: WifiManager.MulticastLock? = null
    private var pendingStart: MethodChannel.Result? = null
    private var busy = false
    private var running = false
    private var generation = 0
    @Volatile private var frames = 0L
    // Accessed by the bridge only on the Android main thread. A live JNI host
    // must remain stoppable even if its decoder reports an error.
    val isActive: Boolean get() = busy || running
    private fun send(message: String, state: String = "waiting") {
        main.post { emit(mapOf("state" to state, "message" to message)) }
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
    }
    fun start(requestedName: String, result: MethodChannel.Result) {
        if (busy || running) { result.error("busy", "接收器已启动或正在操作", null); return }
        val name = requestedName.trim()
        if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > 50 ||
            name.any { it.code < 32 || it.code == 127 }) {
            result.error("name", "设备名需要 1–50 个 UTF-8 字节，不能含控制字符", null); return
        }
        pendingStart = result
        busy = true
        val epoch = ++generation
        frames = 0
        try {
            logDisplayInfo()
            diagnostic("Receiver request: H.264, 1920x1080, maxFPS=60; sender chooses actual size/rate")
            texture = textures.createSurfaceTexture().also { it.surfaceTexture().setDefaultBufferSize(1920, 1080) }
            surface = Surface(texture!!.surfaceTexture())
            renderer = VideoRenderer().also {
                it.onDiagnostic = ::diagnostic
                it.selectDecoder(60)
                it.setResolution(1920,1080)
                it.setSurface(surface!!)
                it.onError = { frames=0;send(it, "error") }
                it.onOutput = { if (frames++ == 0L) send("正在播放屏幕镜像", "playing") }
            }
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
                val prefs=context.getSharedPreferences("receiver", Context.MODE_PRIVATE)
                val hex=prefs.getString("identity",null) ?: ByteArray(6).also {
                    SecureRandom().nextBytes(it); it[0]=((it[0].toInt() or 2) and 254).toByte()
                }.joinToString("") { "%02X".format(it.toInt() and 255) }.also {
                    prefs.edit().putString("identity",it).apply()
                }
                val identity=hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
                val port=startNative(name,identity,File(context.filesDir,"airplay-pairing.pem").absolutePath)
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
                        result.success(mapOf("textureId" to texture!!.id(), "width" to 1920,"height" to 1080, "name" to name))
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
        // This player advertises only the encoded audio formats it decodes.
        if(items.containsKey("cn"))items["cn"]="1,2,3".toByteArray()
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
        override fun onUnregistrationFailed(value:NsdServiceInfo,code:Int) { send("设备发现注销失败 ($code)","error") }
    }
    fun stop(result:MethodChannel.Result) {
        if(busy && !running) { result.error("busy","正在启动，请稍后停止",null);return }
        stopInternal(result)
    }
    // Backgrounding must cancel startup too, even before discovery is ready.
    fun stopForBackground(result: MethodChannel.Result) { stopInternal(result) }
    private fun stopInternal(result:MethodChannel.Result?) {
        pendingStart?.error("cancelled", "应用已离开前台", null)
        pendingStart = null
        ++generation;busy=true;running=false
        registrations.forEach { it.cancel() };registrations.clear()
        worker.execute {
            stopNative()
            main.post { cleanupSurface();busy=false;send("接收器已停止","stopped");result?.success(null) }
        }
    }
    private fun cleanupSurface() {
        renderer?.release();renderer=null
        surface?.release();surface=null
        texture?.release();texture=null
        multicast?.let { if(it.isHeld)it.release() };multicast=null
    }
    fun close() { stopInternal(null); worker.shutdown() }
    // JNI callbacks stay off the UI thread; only state events are marshalled to it.
    fun onClientName(bytes: ByteArray) {
        val name = bytes.toString(Charsets.UTF_8).filter { it.code >= 32 && it.code != 127 }.trim()
        main.post { emit(mapOf("clientName" to name, "state" to "connecting")) }
    }
    fun onVideoData(data:ByteArray,pts:Long) { renderer?.feedFrame(data,pts) }
    fun onVideoSize(width:Int,height:Int,streamWidth:Int,streamHeight:Int) {
        diagnostic("Protocol video: source=${width}x${height}, stream=${streamWidth}x${streamHeight}")
        renderer?.setResolution(width,height)
        main.post {
            texture?.surfaceTexture()?.setDefaultBufferSize(width,height)
            diagnostic("Flutter texture requested: ${width}x${height}")
            emit(mapOf("width" to width,"height" to height))
        }
    }
    fun onVideoReset() { renderer?.stopSession(); frames=0;send("等待屏幕镜像", "reset") }
    fun onNativeState(message:String) { send(message, if(message == "mirroring") "connecting" else if(frames>0) "playing" else "waiting") }
    private external fun startNative(name:String,identity:ByteArray,keyPath:String):Int
    private external fun txtNative(raop:Boolean):ByteArray
    private external fun stopNative()
}
