// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay.audio;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTimestamp;
import android.media.AudioTrack;

/** Called by the native writer thread; pause interrupts a blocking write before join. */
public final class AudioTrackSink {
    public static final int BLOCK_FRAMES = 441;
    private final AudioTrack track;
    private final AudioTimestamp timestamp = new AudioTimestamp();
    private long written;
    private final PlaybackProgress progress = new PlaybackProgress();

    public AudioTrackSink() {
        int minimum = AudioTrack.getMinBufferSize(44100, AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT);
        if (minimum <= 0) throw new IllegalStateException("AudioTrack minimum buffer: " + minimum);
        int blockBytes = BLOCK_FRAMES * 4;
        int bytes = ((Math.max(minimum, blockBytes * 3) + blockBytes - 1) / blockBytes) * blockBytes;
        track = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(new AudioFormat.Builder().setSampleRate(44100)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_NONE)
                .setBufferSizeInBytes(bytes).build();
        try {
            if (track.getState() != AudioTrack.STATE_INITIALIZED)
                throw new IllegalStateException("AudioTrack not initialized");
            track.play();
        } catch (RuntimeException error) {
            track.release();
            throw error;
        }
    }

    public int write(short[] pcm, int offset, int count) {
        int result = track.write(pcm, offset, count, AudioTrack.WRITE_BLOCKING);
        if (result > 0) written += result / 2;
        return result;
    }

    public long presentationTimeNs() {
        long now = System.nanoTime();
        long played = progress.update(track.getPlaybackHeadPosition());
        if (track.getTimestamp(timestamp)) {
            // AudioTimestamp and playback head share the same frame origin.
            long position = (played & ~0xffffffffL) | (timestamp.framePosition & 0xffffffffL);
            if (position > played + 0x80000000L) position -= 0x100000000L;
            if (position < played - 0x80000000L) position += 0x100000000L;
            long due = timestamp.nanoTime + Math.max(0, written - position) * 1000000000L / 44100;
            if (due >= now && due < now + 500000000L) return due;
        }
        // During warmup, queued frames plus one write block avoid treating a
        // full device buffer as already audible. Never use the write time alone.
        return now + (Math.max(0, written - played) + BLOCK_FRAMES) * 1000000000L / 44100;
    }

    public void interrupt() {
        track.pause();
        track.flush();
    }
    public void release() {
        try { track.stop(); } finally { track.release(); }
    }
    public int sampleRate() { return track.getSampleRate(); }
    public int bufferFrames() { return track.getBufferSizeInFrames(); }
    public int underruns() { return track.getUnderrunCount(); }
}
