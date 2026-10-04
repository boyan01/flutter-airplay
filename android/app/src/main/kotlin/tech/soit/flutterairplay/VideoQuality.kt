// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay

/** AirPlay uses height as a request, then adjusts width to the sender's aspect. */
internal object VideoQuality {
    val presets = listOf("auto", "720", "1080", "1440", "2160")

    // Lower presets reserve room for tall-phone landscape streams (up to 2.4:1).
    // UHD checks the advertised 16:9 size; requiring 5184px would exclude 4K decoders.
    fun decoderWidth(height: Int): Int =
        if (height == 2160) width(height) else ((height * 12 / 5 + 15) / 16) * 16

    fun supported(height: Int, supports: (Int, Int) -> Boolean): Boolean {
        val wide = decoderWidth(height)
        val high = ((height + 15) / 16) * 16
        return wide <= 4096 && supports(wide, high)
    }

    fun height(quality: String, screenHeight: Int, supports: (Int, Int) -> Boolean): Int {
        require(quality in presets) { "Unknown video quality" }
        if (quality != "auto") {
            return quality.toInt().also {
                require(supported(it, supports)) { "The decoder does not support this video quality at 60 FPS" }
            }
        }
        val target = screenHeight.coerceIn(480, 2160) / 2 * 2
        return (listOf(target) + listOf(2160, 1440, 1080, 720, 480).filter { it < target })
            .firstOrNull { supported(it, supports) }
            ?: error("The decoder cannot support a 480p mirroring request at 60 FPS")
    }

    fun width(height: Int): Int = (height * 16 / 9 + 1) / 2 * 2
}
