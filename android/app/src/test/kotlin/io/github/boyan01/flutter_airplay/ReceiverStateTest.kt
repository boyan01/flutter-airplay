// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import org.junit.Assert.*
import org.junit.Test

class ReceiverStateTest {
    private fun ReceiverState.snapshot(pid: Int = 0, tv: Boolean = false) = snapshot("Receiver", pid, tv)
    private fun playingState(): ReceiverState = ReceiverState().apply {
        startRequested()
        started(mapOf("textureId" to 7L, "width" to 1920, "height" to 1080))
        accept(mapOf("state" to "playing", "message" to "decoded output"))
    }

    @Test fun waitingDoesNotClaimDecodedVideo() {
        val state = ReceiverState()
        state.startRequested()
        state.started(mapOf("textureId" to 7L, "width" to 1920, "height" to 1080))
        state.accept(mapOf("state" to "ready", "message" to "registered"))
        val snapshot = state.snapshot(123)
        assertEquals("waiting", snapshot["status"])
        assertEquals(0, snapshot["videoWidth"])
        assertEquals(7L, snapshot["textureId"])
        assertEquals(123, snapshot["pid"])
    }

    @Test fun decodedFrameRestoresVideoAfterDisconnectAndRotation() {
        val state = playingState()
        state.accept(mapOf("state" to "waiting", "message" to "disconnected"))
        assertEquals(0, state.snapshot()["videoWidth"])
        state.accept(mapOf("width" to 1080, "height" to 1920))
        assertEquals(0, state.snapshot()["videoWidth"])
        state.accept(mapOf("state" to "playing", "message" to "decoded output"))
        assertEquals(1080, state.snapshot()["videoWidth"])
        assertEquals(1920, state.snapshot()["videoHeight"])
    }

    @Test fun liveDecoderErrorRemainsStoppableAndDiscoveryErrorSurvivesCleanup() {
        val state = playingState()
        state.error("decoder failed")
        assertEquals(123, state.snapshot(123)["pid"])
        assertEquals(0, state.snapshot(123)["videoWidth"])
        state.accept(mapOf("state" to "stopped", "message" to "stopped"))
        assertEquals("error", state.snapshot()["status"])
        assertEquals("decoder failed", state.snapshot()["message"])
        assertEquals(-1L, state.snapshot()["textureId"])
        state.startRequested()
        assertEquals("starting", state.snapshot()["status"])
    }

    @Test fun explicitStopClearsErrorAndLateDiscoveryDoesNotHideVideo() {
        val state = playingState()
        state.accept(mapOf("state" to "ready", "message" to "registered"))
        assertEquals("streaming", state.snapshot()["status"])
        state.error("decoder failed")
        state.stopRequested()
        state.accept(mapOf("state" to "stopped", "message" to "stopped"))
        assertEquals("stopped", state.snapshot()["status"])
    }

    @Test fun logsAreBoundedAndCapabilitiesAreExplicit() {
        val state = ReceiverState()
        repeat(305) { state.log("entry $it") }
        val snapshot = state.snapshot(tv = true)
        val logs = snapshot["logs"] as List<*>
        assertEquals(300, logs.size)
        assertEquals(6, (logs.first() as Map<*, *>)["id"])
        assertEquals(mapOf("platform" to "android", "isTelevision" to true,
            "supportsExecutablePath" to false), snapshot["capabilities"])
    }

    @Test fun playbackDiagnosticsDoNotChangeReceiverStateOrVideoReadiness() {
        val state = playingState()
        val before = state.snapshot()
        state.accept(mapOf("log" to "Decoder output: coded=1920x1088, visible=1920x1080"))
        val after = state.snapshot()
        assertEquals(before["status"], after["status"])
        assertEquals(before["message"], after["message"])
        assertEquals(before["videoWidth"], after["videoWidth"])
        val logs = after["logs"] as List<*>
        assertEquals("Decoder output: coded=1920x1088, visible=1920x1080",
            (logs.last() as Map<*, *>)["text"])
        state.accept(mapOf("state" to "reset"))
        state.accept(mapOf("log" to "EGL display surface: 1080x1920"))
        assertEquals(0, state.snapshot()["videoWidth"])
    }

    @Test fun connectingWaitsForDecodedVideoAndResetPreservesSender() {
        val state = ReceiverState()
        state.startRequested()
        state.started(mapOf("textureId" to 7L, "width" to 1920, "height" to 1080))
        state.accept(mapOf("state" to "connecting", "clientName" to "Alice’s iPhone"))
        assertEquals("streaming", state.snapshot()["status"])
        assertEquals("Alice’s iPhone", state.snapshot()["clientName"])
        assertEquals(0, state.snapshot()["videoWidth"])
        state.accept(mapOf("state" to "playing"))
        assertEquals(1920, state.snapshot()["videoWidth"])
        state.accept(mapOf("state" to "reset"))
        assertEquals("Alice’s iPhone", state.snapshot()["clientName"])
        assertEquals(0, state.snapshot()["videoWidth"])
        state.accept(mapOf("state" to "waiting"))
        assertEquals("", state.snapshot()["clientName"])
    }

    @Test fun namesRespectSharedUtf8Boundary() {
        assertTrue(ReceiverState.validName("a".repeat(50)))
        assertFalse(ReceiverState.validName("a".repeat(51)))
        assertTrue(ReceiverState.validName("屏".repeat(16)))
        assertFalse(ReceiverState.validName("屏".repeat(17)))
        assertFalse(ReceiverState.validName(""))
        assertFalse(ReceiverState.validName("Receiver\nName"))
    }
}
