// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.boyan01.airplay;

/** Compressed data owned by the caller; all clocks and epochs remain explicit. */
public final class EncodedPacket {
    public final int kind, codec, syncStatus;
    public final long localNtpNanos, rtpTimestamp, epoch;
    public final byte[] data;
    public EncodedPacket(int kind, int codec, long pts, long rtp, int sync, long epoch, byte[] data) {
        this.kind = kind; this.codec = codec; this.localNtpNanos = pts;
        this.rtpTimestamp = rtp; this.syncStatus = sync; this.epoch = epoch; this.data = data;
    }
}
