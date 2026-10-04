// SPDX-License-Identifier: GPL-3.0-only
// Derived from jqssun/android-airplay-server, commit c8defdd70d7e6a04f4f1b71d353653682d594106.
package tech.soit.flutterairplay.renderer

import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecInfo.VideoCapabilities
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log

// moonlight-android MediaCodecHelper
class DecoderSelector {
    var onDiagnostic: ((String) -> Unit)? = null

    private val emulator = Build.HARDWARE == "ranchu" || Build.HARDWARE == "cheets" || Build.BRAND == "Android-x86"

    private val blacklist by lazy {
        buildList {
            if (!emulator) {
                add("omx.google"); add("AVCDecoder")
                if (Build.VERSION.SDK_INT < 29) add("OMX.ffmpeg")
            }

        }
    }

    fun avc(): MediaCodecInfo? = _probableSafe(AVC, CodecProfileLevel.AVCProfileHigh) ?: _first(AVC)

    fun hevc(width: Int, height: Int): MediaCodecInfo? = runCatching {
        _decoders(HEVC).sortedByDescending { _lowLatency(it, HEVC) }.firstOrNull { info ->
            val caps = info.getCapabilitiesForType(HEVC)
            (Build.VERSION.SDK_INT < 29 || info.isHardwareAccelerated) &&
                caps.profileLevels.any { it.profile == CodecProfileLevel.HEVCProfileMain ||
                    it.profile == CodecProfileLevel.HEVCProfileMain10 } &&
                _portraitSafe(width, height) { w, h -> caps.videoCapabilities.areSizeAndRateSupported(w, h, 60.0) }
        }
    }.onFailure { onDiagnostic?.invoke("HEVC capability query failed: ${it.javaClass.simpleName}") }.getOrNull()

    fun software(mime: String, w: Int, h: Int): MediaCodecInfo? =
        MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.firstOrNull { info ->
            !info.isEncoder && info.supportsMime(mime) &&
                (if (Build.VERSION.SDK_INT >= 29) info.isSoftwareOnly
                else info.name.lowercase().let {
                    it.startsWith("omx.google.") || it.startsWith("c2.android.") ||
                        (!it.startsWith("omx.") && !it.startsWith("c2."))
                })
        }?.takeIf { _portraitSafe(w, h, it.videoCaps(mime)::isSizeSupported) }

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
        const val HEVC = MediaFormat.MIMETYPE_VIDEO_HEVC
        fun MediaCodecInfo.videoCaps(mime: String): VideoCapabilities = getCapabilitiesForType(mime).videoCapabilities
    }
}
