// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import org.junit.Assert.*
import org.junit.Test

class VideoQualityTest {
    @Test fun phoneAutoIsCappedAndTelevisionUsesItsDisplayHeight() {
        assertEquals(1440, VideoQuality.height("auto", 2670) { _, _ -> true })
        assertEquals(1080, VideoQuality.height("auto", 1080) { _, _ -> true })
        assertEquals(2560, VideoQuality.width(1440))
    }

    @Test fun autoFallsBackWhenWidePhoneLandscapeExceedsDecoderLimits() {
        val only1080: (Int, Int) -> Boolean = { w, h -> w <= 2592 && h <= 1088 }
        assertEquals(1080, VideoQuality.height("auto", 2670, only1080))
        assertFalse(VideoQuality.supported(1440, only1080))
        assertTrue(VideoQuality.supported(1080, only1080))
    }

    @Test fun capabilityCheckIncludesCodecBlockPaddingAndWideAspect() {
        var dimensions = 0 to 0
        assertTrue(VideoQuality.supported(1080) { w, h -> dimensions = w to h; true })
        assertEquals(2592 to 1088, dimensions)
    }

    @Test fun explicitUnsupportedQualityIsRejectedInsteadOfSilentlyDowngraded() {
        assertThrows(IllegalArgumentException::class.java) {
            VideoQuality.height("1440", 2670) { _, h -> h <= 1088 }
        }
        assertThrows(IllegalArgumentException::class.java) {
            VideoQuality.height("bogus", 2670) { _, _ -> true }
        }
    }
}
