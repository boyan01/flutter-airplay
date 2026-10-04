// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay

import org.junit.Assert.*
import org.junit.Test

class ReceiverLifecycleTest {
    @Test fun backgroundKeepsPendingStartupAndActiveReception() {
        var active = false
        var starts = 0
        val lifecycle = ReceiverLifecycle({ active }, { starts++; active = true })
        lifecycle.onForeground(true)
        assertEquals(1, starts)
        lifecycle.onBackground()
        lifecycle.reconcile()
        assertFalse(lifecycle.foreground)
        assertTrue(active)
        lifecycle.onForeground(true)
        assertEquals(1, starts)
        assertTrue(lifecycle.foreground)
    }

    @Test fun disabledAutoStartStillKeepsAnExistingReceiver() {
        var active = false
        var starts = 0
        val lifecycle = ReceiverLifecycle({ active }, { starts++; active = true })
        lifecycle.onForeground(false)
        assertEquals(0, starts)
        active = true
        lifecycle.onBackground()
        lifecycle.onForeground(false)
        assertTrue(active)
        assertEquals(0, starts)
    }

    @Test fun returningDuringNativeStopWaitsForCompletion() {
        var active = true
        var starts = 0
        val lifecycle = ReceiverLifecycle({ active }, { starts++; active = true })
        lifecycle.onBackground()
        lifecycle.onForeground(true)
        assertEquals(0, starts)
        active = false
        lifecycle.reconcile()
        assertEquals(1, starts)
        lifecycle.reconcile()
        assertEquals(1, starts)
    }

    @Test fun manualStopAndServiceShutdownCancelPendingResume() {
        var active = true
        var starts = 0
        val lifecycle = ReceiverLifecycle({ active }, { starts++ })
        lifecycle.onForeground(true)
        lifecycle.cancelResume()
        active = false
        lifecycle.reconcile()
        assertEquals(0, starts)
        lifecycle.close()
        lifecycle.onForeground(true)
        assertEquals(0, starts)
    }

    @Test fun backgroundDoesNotRestartAnInactiveReceiver() {
        var active = true
        var starts = 0
        val lifecycle = ReceiverLifecycle({ active }, { starts++ })
        lifecycle.onForeground(true)
        lifecycle.onBackground()
        active = false
        lifecycle.reconcile()
        assertEquals(0, starts)
    }
}
