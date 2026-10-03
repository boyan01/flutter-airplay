// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import org.junit.Assert.*
import org.junit.Test

class ReceiverLifecycleTest {
    @Test fun backgroundStopsPendingStartupAndForegroundWaitsForStop() {
        var active = true // PlaybackHost also marks pending startup active.
        var stops = 0
        var starts = 0
        var completion: ((Boolean) -> Unit)? = null
        val lifecycle = ReceiverLifecycle({ active }, { stops++; completion = it }, { starts++; active = true })
        lifecycle.onBackground()
        lifecycle.reconcile()
        assertEquals(1, stops)
        lifecycle.onForeground(true)
        assertEquals(0, starts)
        active = false
        completion!!(true)
        assertEquals(1, starts)
        lifecycle.reconcile()
        assertEquals(1, starts)
    }

    @Test fun disabledAutoStartAndShutdownDoNotResume() {
        var active = true
        var starts = 0
        var completion: ((Boolean) -> Unit)? = null
        val lifecycle = ReceiverLifecycle({ active }, { completion = it }, { starts++ })
        lifecycle.onBackground()
        lifecycle.onForeground(false)
        active = false
        completion!!(true)
        assertEquals(0, starts)
        lifecycle.onForeground(true)
        assertEquals(1, starts)
        lifecycle.close()
        lifecycle.onForeground(true)
        assertEquals(1, starts)
    }

    @Test fun returningToBackgroundDuringStopCancelsResume() {
        var active = true
        var starts = 0
        var completion: ((Boolean) -> Unit)? = null
        val lifecycle = ReceiverLifecycle({ active }, { completion = it }, { starts++ })
        lifecycle.onBackground()
        lifecycle.onForeground(true)
        lifecycle.onBackground()
        active = false
        completion!!(true)
        assertEquals(0, starts)
    }
    @Test fun manualStopCancelsPendingForegroundResume() {
        var active = true
        var starts = 0
        val lifecycle = ReceiverLifecycle({ active }, { it(true) }, { starts++ })
        lifecycle.onForeground(true)
        lifecycle.cancelResume()
        active = false
        lifecycle.reconcile()
        assertEquals(0, starts)
    }

}
