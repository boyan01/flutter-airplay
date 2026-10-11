// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class VideoPresentationTest {
    private fun arguments() = mutableMapOf<String, Any>(
        "left" to 0.25, "top" to 0.1, "width" to 0.5, "height" to 0.5)

    @Test fun acceptsNormalizedCropAndOptionalSourceDimensions() {
        assertEquals(VideoPresentation(0.25, 0.1, 0.5, 0.5), VideoPresentation.parse(arguments()))
        val values = arguments().apply { put("sourceWidth", 1920); put("sourceHeight", 1080) }
        assertEquals(VideoPresentation(0.25, 0.1, 0.5, 0.5, 1920.0, 1080.0), VideoPresentation.parse(values))
    }

    @Test fun clampsBoundaryRoundingButRejectsOutOfBounds() {
        val values = arguments().apply { put("width", 0.75 + 5e-10); put("height", 0.9 + 5e-10) }
        assertEquals(VideoPresentation(0.25, 0.1, 0.75, 0.9), VideoPresentation.parse(values))
        for ((key, value) in listOf("width" to (0.75 + 2e-9), "height" to (0.9 + 2e-9), "left" to 1.0, "top" to 1.0)) {
            assertThrows(IllegalArgumentException::class.java) {
                VideoPresentation.parse(values.toMutableMap().apply { put(key, value) })
            }
        }
    }

    @Test fun rejectsInvalidRectanglesAndIncompleteSourceDimensions() {
        for ((key, value) in listOf(
            "left" to -0.1, "top" to 0.8, "width" to 0.0, "height" to 1.0,
            "left" to false, "width" to Double.NaN, "height" to Double.POSITIVE_INFINITY,
            "sourceWidth" to 1920, "sourceHeight" to 0,
        )) {
            assertThrows(IllegalArgumentException::class.java) {
                VideoPresentation.parse(arguments().apply { put(key, value) })
            }
        }
        assertThrows(IllegalArgumentException::class.java) { VideoPresentation.parse(null) }
        assertThrows(IllegalArgumentException::class.java) { VideoPresentation.parse(emptyMap<String, Any>()) }
    }
    @Test fun acceptsEditorViewportAndRejectsIncompleteOrOutsideAreas() {
        val values = arguments().apply {
            put("viewportLeft", 0.1); put("viewportTop", 0.2)
            put("viewportWidth", 0.8); put("viewportHeight", 0.6)
        }
        assertEquals(VideoPresentation(0.25, 0.1, 0.5, 0.5, viewportLeft = 0.1, viewportTop = 0.2,
            viewportWidth = 0.8, viewportHeight = 0.6), VideoPresentation.parse(values))
        for ((key, value) in listOf("viewportTop" to -0.1, "viewportWidth" to 1.0,
            "viewportHeight" to 0.0, "viewportLeft" to Double.NaN)) {
            assertThrows(IllegalArgumentException::class.java) {
                VideoPresentation.parse(values.toMutableMap().apply { put(key, value) })
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            VideoPresentation.parse(arguments().apply { put("viewportTop", 0.2) })
        }
    }

}
