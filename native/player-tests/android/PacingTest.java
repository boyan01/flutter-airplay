// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.player_regression;

import android.os.Looper;
import android.util.Log;
import android.view.Surface;

/** Measures the production receiver worker against a GPU texture consumer. */
public final class PacingTest {
    private static native String run(Surface surface, String decoder,
                                     TextureSurface consumer, int batch);

    static void check(String decoder) {
        for (int batch : new int[]{1, 3, 9}) {
            try (TextureSurface consumer = new TextureSurface(640, 360)) {
                String result = run(consumer.surface, decoder, consumer, batch);
                Log.i("PlayerRegression", decoder + " " + result);
                System.out.println(decoder + " " + result);
                if (!result.startsWith("PACING_OK:")) throw new IllegalStateException(result);
                consumer.checkRedPixels();
            }
        }
    }

    // A fast, unattended entry point without replacing or opening the product app.
    public static void main(String[] args) {
        Looper.prepareMainLooper();
        System.load(args[0] + "/libairplay_player.so");
        System.load(args[0] + "/libplayer_regression.so");
        try {
            check(args[1]);
            System.out.println("PASS: receiver frame pacing");
            System.exit(0);
        } catch (Throwable error) {
            System.err.println("FAIL: " + error);
            System.exit(1);
        }
    }
}
