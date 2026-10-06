// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay.player_regression;

import android.os.Looper;
import android.util.Log;
import android.view.Surface;

/** Qualcomm buffering regression and presentation ordering with real B-frames. */
public final class ReorderTest {
    private static native String run(Surface surface, String decoder,
                                     TextureSurface consumer, boolean bframes);

    static void check(String decoder) {
        for (boolean bframes : new boolean[]{false, true}) {
            try (TextureSurface consumer = new TextureSurface(2560, 1440)) {
                String result = run(consumer.surface, decoder, consumer, bframes);
                Log.i("PlayerRegression", decoder + " " + result);
                System.out.println(decoder + " " + result);
                if (!result.startsWith("ORDER_OK:")) throw new IllegalStateException(result);
                consumer.checkRedPixels();
            }
        }
    }

    public static void main(String[] args) {
        Looper.prepareMainLooper();
        System.load(args[0] + "/libairplay_player.so");
        System.load(args[0] + "/libplayer_regression.so");
        try {
            check(args[1]);
            System.out.println("PASS: decoder buffering and presentation order");
            System.exit(0);
        } catch (Throwable error) {
            System.err.println("FAIL: " + error);
            System.exit(1);
        }
    }
}
