// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay.player_regression;

import android.os.Looper;
import android.util.Log;
import android.view.Surface;

/** Measures the production receiver worker against a GPU texture consumer. */
public final class PacingTest {
    private static native String run(Surface surface, String decoder,
                                     TextureSurface consumer, int batch, int refreshHz, int phaseMs);

    static void check(String decoder, boolean sweep, int... batches) {
        boolean failed = false;
        for (int refresh : (sweep ? new int[]{120, 60} : new int[]{120})) for (int phase : (sweep ? new int[]{0, 3, 7, 11, 15} : new int[]{0})) for (int batch : batches) {
            try (TextureSurface consumer = new TextureSurface(640, 360)) {
                String result = run(consumer.surface, decoder, consumer, batch, refresh, phase);
                Log.i("PlayerRegression", decoder + " " + result);
                System.out.println(decoder + " " + result);
                if (!result.startsWith("PACING_OK:")) failed = true;
                consumer.checkRedPixels();
            }
        }
        if (failed) throw new IllegalStateException("Frame pacing phase sweep failed");
    }

    // A fast, unattended entry point without replacing or opening the product app.
    public static void main(String[] args) {
        Looper.prepareMainLooper();
        System.load(args[0] + "/libairplay_player.so");
        System.load(args[0] + "/libplayer_regression.so");
        try {
            check(args[1], args.length > 2 && args[2].equals("--phase-sweep"), 1, 3, 9);
            System.out.println("PASS: receiver frame pacing");
            System.exit(0);
        } catch (Throwable error) {
            System.err.println("FAIL: " + error);
            System.exit(1);
        }
    }
}
