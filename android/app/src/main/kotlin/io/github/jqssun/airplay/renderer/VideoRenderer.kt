// SPDX-License-Identifier: GPL-3.0-only
// Derived from jqssun/android-airplay-server, commit c8defdd70d7e6a04f4f1b71d353653682d594106.
package io.github.jqssun.airplay.renderer

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import android.view.Surface

class VideoRenderer {
    var onError: ((String) -> Unit)? = null
    var onOutput: (() -> Unit)? = null

    private val lock = Object()
    private val pipeline = VideoPipeline()
    private val selector = DecoderSelector()
    private var avcDecoder: MediaCodecInfo? = null
    private var maxFps = 0
    private var codec: MediaCodec? = null
    private var videoWidth = 0
    private var videoHeight = 0
    private var firstFrameQueued = false

    private var droppedFrames = 0L
    // anchors that map decoder PTS (us) to System.nanoTime() for scheduled rendering
    private var _ptsBaseUs = Long.MIN_VALUE
    private var _wallBaseNs = 0L

    fun setResolution(w: Int, h: Int) {
        videoWidth = w
        videoHeight = h
        pipeline.setVideoSize(w, h)
    }

    // doesn't restart codec; decoder renders into pipeline's own persistent surface
    fun setSurface(surface: Surface) = synchronized(lock) {
        pipeline.setDisplaySurface(surface)
    }

    fun selectDecoder(fps: Int) = synchronized(lock) {
        avcDecoder = selector.avc()
        maxFps = fps
        Log.i(TAG, "decoder: avc=${avcDecoder?.name}")
    }

    fun stopSession() = synchronized(lock) { stopCodec() }

    fun feedFrame(data: ByteArray, ntpTimeNs: Long) {
        synchronized(lock) {
            if (videoWidth == 0 || videoHeight == 0) return

            if (codec == null) {
                // a stale reference frame decodes to corruption, so wait for a keyframe to (re)start
                if (!_isKeyframe(data)) {
                    return
                }
            }

            try {
                if (codec == null) startCodec()
                _feedToCodec(data, ntpTimeNs)
                drainOutput()
            } catch (e: Exception) {
                Log.w(TAG, "Codec error, resetting", e)
                onError?.invoke("视频解码失败，请重新连接屏幕镜像")
                stopCodec()
            }
        }
    }

    private fun _feedToCodec(data: ByteArray, ntpTimeNs: Long) {
        val c = codec ?: return
        // dropping a frame desyncs decoder until the next keyframe, but source would only send one on (re)connect
        val retries = if (firstFrameQueued) FEED_RETRIES else FIRST_FEED_RETRIES
        repeat(retries) {
            val idx = c.dequeueInputBuffer(FEED_WAIT_US)
            if (idx >= 0) {
                val buf = c.getInputBuffer(idx) ?: return
                buf.clear()
                buf.put(data)
                c.queueInputBuffer(idx, 0, data.size, ntpTimeNs / 1000, 0)
                firstFrameQueued = true
                return
            }
            drainOutput()
        }
        droppedFrames++
        Log.w(TAG, "Decoder input queue full; dropping frame. drops=$droppedFrames")
    }

    private fun _isKeyframe(data: ByteArray): Boolean {
        if (data.size < 5) return false
        var i = 0
        while (i <= data.size - 5) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() &&
                data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                val type = data[i + 4].toInt() and 0x1F
                val key = type == 5 || type == 7
                if (key) return true
            }
            i++
        }
        return false
    }

    private fun startCodec() {
        pipeline.start()
        pipeline.setVideoSize(videoWidth, videoHeight)
        val s = pipeline.inputSurface ?: return
        val mime = DecoderSelector.AVC
        val info = avcDecoder ?: error("no decoder selected for $mime")

        firstFrameQueued = false
        try {
            _startWithLadder(info, mime, s)
        } catch (e: Exception) {
            // strict hw decoders reject configs beyond their real limits
            val sw = selector.software(mime, videoWidth, videoHeight) ?: throw e
            Log.w(TAG, "Hardware decoder failed, trying software fallback", e)
            _startWithLadder(sw, mime, s)
        }
        Log.i(TAG, "Video codec started: $mime ${videoWidth}x${videoHeight}")
    }

    private fun _startWithLadder(info: MediaCodecInfo, mime: String, s: Surface) {
        var tryNum = 0
        while (true) {
            val format = _format(mime, info)
            val more = selector.lowLatencyOptions(format, info, mime, tryNum)
            try {
                _startDecoder(MediaCodec.createByCodecName(info.name), format, s)
                return
            } catch (e: Exception) {
                if (!more) throw e
                Log.w(TAG, "configure try $tryNum failed: $format", e)
                tryNum++
            }
        }
    }

    private fun _format(mime: String, info: MediaCodecInfo) = MediaFormat.createVideoFormat(mime, videoWidth, videoHeight).apply {
        setInteger(MediaFormat.KEY_FRAME_RATE, maxFps)
        if (selector.adaptive(info, mime)) {
            setInteger(MediaFormat.KEY_MAX_WIDTH, videoWidth)
            setInteger(MediaFormat.KEY_MAX_HEIGHT, videoHeight)
        }
        setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(videoWidth * videoHeight * 3 / 4, 1024 * 1024))
        setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
        setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
        setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            setInteger(MediaFormat.KEY_ALLOW_FRAME_DROP, 1)
        }
    }

    private fun _startDecoder(c: MediaCodec, format: MediaFormat, surface: Surface) {
        try {
            c.configure(format, surface, null, 0)
            c.start()
        } catch (e: Exception) {
            try { c.release() } catch (_: Exception) {}
            throw e
        }
        codec = c
        Log.i(TAG, "Video decoder started: ${c.name}")
    }

    private fun stopCodec() {
        _ptsBaseUs = Long.MIN_VALUE
        _wallBaseNs = 0L
        codec?.let {
            try {
                it.stop()
                it.release()
            } catch (_: Exception) {}
        }
        codec = null
    }

    private fun drainOutput() {
        val c = codec ?: return
        val info = MediaCodec.BufferInfo()
        while (true) {
            val idx = c.dequeueOutputBuffer(info, 0)
            if (idx < 0) break
            onOutput?.invoke()
            // Schedule output against the session's monotonic PTS anchor.
            val ptsUs = info.presentationTimeUs
            if (_ptsBaseUs == Long.MIN_VALUE) {
                _ptsBaseUs = ptsUs
                _wallBaseNs = System.nanoTime()
            }
            c.releaseOutputBuffer(idx, _wallBaseNs + (ptsUs - _ptsBaseUs) * 1000L)
        }
    }

    fun release() = synchronized(lock) {
        stopCodec()
        pipeline.release()
    }

    companion object {
        private const val TAG = "VideoRenderer"
        private const val FEED_WAIT_US = 20_000L
        private const val FEED_RETRIES = 10
        private const val FIRST_FEED_RETRIES = 50
    }
}
