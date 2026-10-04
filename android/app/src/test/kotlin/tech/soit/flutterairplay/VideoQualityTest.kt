// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay

import org.junit.Assert.*
import org.junit.Test

class VideoQualityTest {
    @Test fun phoneAutoIsCappedAndTelevisionUsesItsDisplayHeight() {
        assertEquals(2160, VideoQuality.height("auto", 2670) { _, _ -> true })
        assertEquals(1080, VideoQuality.height("auto", 1080) { _, _ -> true })
        assertEquals(2560, VideoQuality.width(1440))
    }

    @Test fun fourKUsesUhdDimensionsAndFallsBackOnLimitedDecoders() {
        val uhd: (Int, Int) -> Boolean = { w, h -> w <= 3840 && h <= 2160 }
        assertEquals(2160, VideoQuality.height("2160", 1080, uhd))
        assertEquals(3840, VideoQuality.width(2160))
        assertEquals(2160, VideoQuality.height("auto", 2160, uhd))
        assertEquals(1440, VideoQuality.height("auto", 2160) { w, h -> w <= 4096 && h <= 1440 })
        assertThrows(IllegalArgumentException::class.java) {
            VideoQuality.height("2160", 2160) { _, h -> h <= 1440 }
        }
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
