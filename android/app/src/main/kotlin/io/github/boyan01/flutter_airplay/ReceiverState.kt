// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import java.time.Instant

/** Main-thread state adapter for the shared Flutter ReceiverModel contract. */
internal class ReceiverState {
    var status = "stopped"
        private set
    var message = "接收器未启动"
        private set
    var textureId = -1L
        private set
    private var width = 1920
    private var height = 1080
    private var clientName = ""
    private var decodedVideo = false
    private var failure: String? = null
    private var logId = 0
    private val logs = ArrayDeque<Map<String, Any>>()

    fun startRequested() {
        failure = null
        clientName = ""
        decodedVideo = false
        textureId = -1L
        width = 1920
        height = 1080
        state("starting", "正在启动接收器")
    }

    fun stopRequested() {
        failure = null
        state("stopping", "正在停止接收器")
    }

    fun started(data: Map<*, *>) {
        textureId = (data["textureId"] as Number).toLong()
        width = (data["width"] as Number).toInt()
        height = (data["height"] as Number).toInt()
    }

    fun accept(event: Map<String, Any>) {
        (event["log"] as? String)?.let(::log)
        (event["clientName"] as? String)?.let { clientName = it }
        (event["width"] as? Number)?.let { width = it.toInt() }
        (event["height"] as? Number)?.let { height = it.toInt() }
        val raw = event["state"] as? String ?: return
        val detail = event["message"] as? String ?: message
        when (raw) {
            "ready" -> state(if (status == "streaming") "streaming" else "waiting", detail)
            "reset" -> { decodedVideo = false; state(if (clientName.isEmpty()) "waiting" else "streaming", detail) }
            "connecting" -> { if (!decodedVideo) state("streaming", detail) }
            "playing" -> { failure = null; decodedVideo = true; state("streaming", detail) }
            "error" -> error(detail)
            "stopped" -> {
                clientName = ""
                decodedVideo = false
                textureId = -1L
                state(if (failure == null) "stopped" else "error", failure ?: detail)
            }
            "waiting", "starting" -> { decodedVideo = false; if (raw == "waiting") clientName = ""; state(raw, detail) }
        }
    }

    fun error(detail: String) {
        decodedVideo = false
        failure = detail
        state("error", detail)
    }

    fun log(text: String) {
        logs.addLast(mapOf("id" to ++logId, "time" to Instant.now().toString(),
            "text" to text.take(4096)))
        while (logs.size > 300) logs.removeFirst()
    }

    private fun state(next: String, detail: String) {
        if (status != next || message != detail) log(detail)
        status = next
        message = detail
    }

    fun snapshot(name: String, activePid: Int, isTelevision: Boolean): Map<String, Any> = mapOf(
        "status" to status, "message" to message, "pid" to activePid,
        "clientName" to clientName, "name" to name, "path" to "", "textureId" to textureId,
        // The root model displays video only after a real decoded output buffer.
        "videoWidth" to if (status == "streaming" && decodedVideo) width else 0,
        "videoHeight" to if (status == "streaming" && decodedVideo) height else 0,
        "logs" to logs.toList(),
        "capabilities" to mapOf("platform" to "android", "isTelevision" to isTelevision,
            "supportsExecutablePath" to false),
    )

    companion object {
        fun validName(name: String): Boolean = name.isNotEmpty() &&
            name.toByteArray(Charsets.UTF_8).size <= 50 &&
            name.none { it.code < 32 || it.code == 127 }
    }
}
