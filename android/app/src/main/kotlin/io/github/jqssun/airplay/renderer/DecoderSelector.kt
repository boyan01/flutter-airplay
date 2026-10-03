// SPDX-License-Identifier: GPL-3.0-only
// Derived from jqssun/android-airplay-server, commit c8defdd70d7e6a04f4f1b71d353653682d594106.
package io.github.jqssun.airplay.renderer

import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecInfo.VideoCapabilities
import android.media.MediaCodecList
import android.media.MediaFormat
import android.opengl.GLES20
import android.os.Build
import android.util.Log

// moonlight-android MediaCodecHelper
class DecoderSelector {
    var onDiagnostic: ((String) -> Unit)? = null

    private val emulator = Build.HARDWARE == "ranchu" || Build.HARDWARE == "cheets" || Build.BRAND == "Android-x86"

    private val glRenderer by lazy {
        runCatching { EglCore().use { GLES20.glGetString(GLES20.GL_RENDERER) ?: "" } }
            .getOrDefault("").lowercase().also {
                Log.i(TAG, "gl renderer: $it")
                onDiagnostic?.invoke("gl renderer: $it")
            }
    }
    private val adreno by lazy {
        if ("adreno" !in glRenderer) -1
        else Regex("\\d{3}").findAll(glRenderer).lastOrNull()?.value?.toInt() ?: -1
    }
    private val blacklist by lazy {
        buildList {
            if (!emulator) {
                add("omx.google"); add("AVCDecoder")
                if (Build.VERSION.SDK_INT < 29) add("OMX.ffmpeg")
            }

        }
    }

    fun avc(): MediaCodecInfo? = _probableSafe(AVC, CodecProfileLevel.AVCProfileHigh) ?: _first(AVC)

    fun software(mime: String, w: Int, h: Int): MediaCodecInfo? =
        MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.firstOrNull { info ->
            !info.isEncoder && info.supportsMime(mime) &&
                (if (Build.VERSION.SDK_INT >= 29) info.isSoftwareOnly
                else info.name.lowercase().let {
                    it.startsWith("omx.google.") || it.startsWith("c2.android.") ||
                        (!it.startsWith("omx.") && !it.startsWith("c2."))
                })
        }?.takeIf { _portraitSafe(w, h, it.videoCaps(mime)::isSizeSupported) }

    fun adaptive(info: MediaCodecInfo, mime: String) = !_inList(noAdaptive, info.name) &&
        runCatching { info.getCapabilitiesForType(mime).isFeatureSupported(CodecCapabilities.FEATURE_AdaptivePlayback) }
            .getOrDefault(false)

    // most to least risky
    fun lowLatencyOptions(format: MediaFormat, info: MediaCodecInfo, mime: String, tryNum: Int): Boolean {
        var set = false
        if (tryNum < 1) {
            format.setInteger("low-latency", 1)
            if (_lowLatency(info, mime)) return true
            set = true
        }
        if (tryNum < 2) {
            format.setInteger("vdec-lowlatency", 1)
            set = true
        }
        if (tryNum < 3) {
            val max = _inList(qti, info.name) && adreno != 620
            if (max) format.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
            else format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            set = true
        }
        if (Build.VERSION.SDK_INT >= 26) {
            if (_inList(qti, info.name)) {
                if (tryNum < 4) { format.setInteger("vendor.qti-ext-dec-picture-order.enable", 1); set = true }
                if (tryNum < 5) { format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1); set = true }
            } else if (tryNum < 4) {
                vendorLowLatency.firstOrNull { (prefixes, _) -> _inList(prefixes, info.name) }?.let { (_, keys) ->
                    keys.forEach { (k, v) -> format.setInteger(k, v) }
                    set = true
                }
            }
        }
        return set
    }

    private fun _decoders(mime: String) =
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
            !info.isEncoder && (Build.VERSION.SDK_INT < 29 || !info.isAlias) &&
                info.supportsMime(mime) && !_blacklisted(info)
        }

    private fun _blacklisted(info: MediaCodecInfo) =
        (!emulator && Build.VERSION.SDK_INT >= 29 && info.isSoftwareOnly) || _inList(blacklist, info.name)

    private fun _probableSafe(mime: String, profile: Int) = try {
        _knownSafe(mime, profile)
    } catch (e: Exception) {
        Log.w(TAG, "caps query failed", e)
        onDiagnostic?.invoke("caps query failed: ${e.stackTraceToString()}")
        _first(mime)
    }

    // include exynos omx and qti
    private fun _knownSafe(mime: String, profile: Int): MediaCodecInfo? {
        val all = _decoders(mime)
        return (0..1).firstNotNullOfOrNull { round ->
            all.firstOrNull { info ->
                (round == 1 || _lowLatency(info, mime)) &&
                    (profile == -1 || info.getCapabilitiesForType(mime).profileLevels.any { it.profile == profile })
            }
        }
    }

    private fun _first(mime: String) = _decoders(mime).firstOrNull()

    private fun _lowLatency(info: MediaCodecInfo, mime: String) = Build.VERSION.SDK_INT >= 30 &&
        runCatching { info.getCapabilitiesForType(mime).isFeatureSupported(CodecCapabilities.FEATURE_LowLatency) }
            .getOrDefault(false)

    // some decoders might only report landscape limit
    private fun _portraitSafe(w: Int, h: Int, check: (Int, Int) -> Boolean) = check(w, h) || (w < h && check(h, w))

    private fun _inList(prefixes: List<String>, name: String) = prefixes.any { name.startsWith(it, ignoreCase = true) }

    private fun MediaCodecInfo.supportsMime(mime: String) = supportedTypes.any { it.equals(mime, ignoreCase = true) }

    companion object {
        private const val TAG = "DecoderSelector"
        const val AVC = MediaFormat.MIMETYPE_VIDEO_AVC
        private val qti = listOf("omx.qcom", "c2.qti")
        private val noAdaptive = listOf("omx.intel", "omx.mtk")
        private val vendorLowLatency = listOf(
            listOf("omx.hisi", "c2.hisi") to mapOf(
                "vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req" to 1,
                "vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-rdy" to -1,
            ),
            listOf("omx.exynos", "c2.exynos") to mapOf("vendor.rtc-ext-dec-low-latency.enable" to 1),
            listOf("omx.amlogic", "c2.amlogic") to mapOf("vendor.low-latency.enable" to 1),
        )

        fun MediaCodecInfo.videoCaps(mime: String): VideoCapabilities = getCapabilitiesForType(mime).videoCapabilities
    }
}
