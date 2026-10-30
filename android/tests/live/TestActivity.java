// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay.live_regression;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

public class TestActivity extends Activity implements SurfaceHolder.Callback {
    private void snapshot(Surface surface, String name) {
        android.graphics.Bitmap pixels = android.graphics.Bitmap.createBitmap(640, 360, android.graphics.Bitmap.Config.ARGB_8888);
        android.view.PixelCopy.request(surface, pixels, status -> {
            if (status != android.view.PixelCopy.SUCCESS) { Log.e("LycheeLiveTest", "FAIL: PixelCopy " + status); return; }
            java.io.File file = new java.io.File(getExternalFilesDir(null), name + ".png");
            try (java.io.OutputStream output = new java.io.FileOutputStream(file)) {
                pixels.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output);
                Log.i("LycheeLiveTest", "snapshot " + file + " pts=0 size=640x360");
            } catch (Exception error) { Log.e("LycheeLiveTest", "FAIL: " + error); }
            finally { pixels.recycle(); }
        }, new android.os.Handler(getMainLooper()));
    }
    static { System.loadLibrary("lychee"); System.loadLibrary("airplay_player"); System.loadLibrary("lychee_live_tests"); }
    private native String run(Surface surface, String path);
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        for (String name : new String[]{"red", "paused", "blue"})
            new java.io.File(getExternalFilesDir(null), name + ".png").delete();
        SurfaceView video = new SurfaceView(this);
        video.getHolder().setFixedSize(640, 360);
        video.getHolder().addCallback(this);
        setContentView(video);
    }
    @Override public void surfaceCreated(SurfaceHolder holder) {
        android.os.Handler handler = new android.os.Handler(getMainLooper());
        handler.postDelayed(() -> snapshot(holder.getSurface(), "red"), 600);
        handler.postDelayed(() -> snapshot(holder.getSurface(), "paused"), 1900);
        handler.postDelayed(() -> snapshot(holder.getSurface(), "blue"), 2800);
        new Thread(() -> {
            String result;
            try {
                java.io.File packets = new java.io.File(getFilesDir(), "eld.packets");
                try (java.io.InputStream input = getAssets().open("eld.packets")) {
                    java.nio.file.Files.copy(input, packets.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                }
                result = run(holder.getSurface(), packets.getAbsolutePath());
            } catch (Exception error) { result = "FAIL: " + error; }
            Log.i("LycheeLiveTest", result);
            runOnUiThread(this::finish);
        }, "live-test").start();
    }
    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}
    @Override public void surfaceDestroyed(SurfaceHolder holder) {}
}
