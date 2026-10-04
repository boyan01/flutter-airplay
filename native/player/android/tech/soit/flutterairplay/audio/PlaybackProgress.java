// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay.audio;

/** Unsigned 32-bit playback head, scoped to one AudioTrack instance. */
public final class PlaybackProgress {
    private long previous;
    private long wraps;
    public long update(int head) {
        long current = Integer.toUnsignedLong(head);
        if (current < previous && previous - current > 0x80000000L) wraps += 0x100000000L;
        previous = current;
        return wraps + current;
    }
}
