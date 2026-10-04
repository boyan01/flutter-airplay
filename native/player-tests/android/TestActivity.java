// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay.player_regression;
import android.app.Activity;
import android.os.Bundle;
import android.media.MediaCodecList;
import android.media.MediaCodecInfo;
import android.os.Build;
import android.media.MediaFormat;
import android.view.Surface;
import android.widget.TextView;
import android.util.Log;
import java.util.LinkedHashSet;
import tech.soit.flutterairplay.audio.PlaybackProgress;

public class TestActivity extends Activity {
    static { System.loadLibrary("airplay_player"); System.loadLibrary("player_regression"); }
    private native String decode(Surface surface, String decoder, boolean portrait);
    private native String hevc(Surface surface, String decoder, String avcDecoder, int variant);
    private native String audio();
    private native String switchSurface(Surface first, Surface second, String decoder, TextureSurface a, TextureSurface b);
    private native String resume(Surface surface, String decoder);
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView label = new TextView(this); label.setText("Running native playback fixtures..."); setContentView(label);
        new Thread(() -> {
            String result;
            try {
                if (getIntent().getBooleanExtra("audioOnly", false)) {
                    String audioResult = audio();
                    Log.i("PlayerRegression", "COMPLETE: " + audioResult);
                    runOnUiThread(() -> label.setText(audioResult));
                    return;
                }
                PlaybackProgress progress = new PlaybackProgress();
                if (progress.update(0xfffffffe) != 4294967294L || progress.update(3) != 4294967299L)
                    throw new IllegalStateException("Playback head wrap failed");
                if (new PlaybackProgress().update(0) != 0)
                    throw new IllegalStateException("Playback head restart failed");
                MediaFormat format = MediaFormat.createVideoFormat("video/avc",640,360);
                String decoder = new MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format);
                if (decoder == null) throw new IllegalStateException("No AVC decoder");
                String hardware = null, software = null, lowLatency = null;
                for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
                    if (info.isEncoder()) continue;
                    if (Build.VERSION.SDK_INT>=29 && info.isSoftwareOnly()) {
                        for (String type : info.getSupportedTypes()) if (type.equalsIgnoreCase("video/avc")) software=info.getName();
                        continue;
                    }
                    if(hardware==null)for (String type : info.getSupportedTypes()) if (type.equalsIgnoreCase("video/avc")) { hardware=info.getName(); break; }
                    if (Build.VERSION.SDK_INT >= 30 && lowLatency == null) {
                        for (String type : info.getSupportedTypes()) {
                            if (type.equalsIgnoreCase("video/avc") && info.getCapabilitiesForType(type)
                                    .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                                lowLatency = info.getName(); break;
                            }
                        }
                    }
                }
                LinkedHashSet<String> decoders=new LinkedHashSet<>();decoders.add(decoder);
                if(hardware!=null)decoders.add(hardware);if(software!=null)decoders.add(software);
                if(lowLatency!=null)decoders.add(lowLatency);
                for (String selected : decoders) {
                    try (TextureSurface a = new TextureSurface(640,360); TextureSurface b = new TextureSurface(640,360)) {
                        String switched = switchSurface(a.surface,b.surface,selected,a,b);
                        if (!switched.startsWith("PASS:")) throw new IllegalStateException(switched);
                        Log.i("PlayerRegression", selected + " " + switched.substring(6));
                    }
                    PacingTest.check(selected);
                }
                for (String selected : decoders) {
                    if (selected.startsWith("c2.qti.") || selected.startsWith("OMX.qcom.")) ReorderTest.check(selected);
                }
                String audioResult = audio();
                if (!audioResult.startsWith("PASS:")) throw new IllegalStateException(audioResult);
                Log.i("PlayerRegression", audioResult.substring(6));
                MediaFormat hevcFormat = MediaFormat.createVideoFormat("video/hevc",640,360);
                String hevcDecoder = new MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(hevcFormat);
                if (hevcDecoder == null) {
                    Log.i("PlayerRegression", "SKIP: HEVC decoder unavailable");
                } else {
                    LinkedHashSet<String> hevcDecoders = new LinkedHashSet<>();
                    hevcDecoders.add(hevcDecoder);
                    if (Build.VERSION.SDK_INT >= 30) {
                        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
                            if (info.isEncoder() || !info.isHardwareAccelerated()) continue;
                            for (String type : info.getSupportedTypes())
                                if (type.equalsIgnoreCase("video/hevc") && info.getCapabilitiesForType(type)
                                        .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency))
                                    hevcDecoders.add(info.getName());
                        }
                    }
                    for (String selected : hevcDecoders) {
                        MediaCodecInfo info = java.util.Arrays.stream(new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos())
                                .filter(value -> value.getName().equals(selected)).findFirst().orElseThrow();
                        MediaCodecInfo.CodecCapabilities caps = info.getCapabilitiesForType("video/hevc");
                        for (int variant = 0; variant < 4; ++variant) {
                            int w = variant == 1 ? 360 : variant == 2 ? 3840 : 640;
                            int h = variant == 1 ? 640 : variant == 2 ? 2160 : 360;
                            MediaFormat fixtureFormat = MediaFormat.createVideoFormat("video/hevc",w,h);
                            if (variant == 3) fixtureFormat.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10);
                            if (!caps.isFormatSupported(fixtureFormat) && !(variant == 1 && caps.getVideoCapabilities().isSizeSupported(h,w))) {
                                Log.i("PlayerRegression", "SKIP: HEVC decoder=" + selected + " variant=" + variant + " exceeds decoder capabilities");
                                continue;
                            }
                            try (TextureSurface consumer = new TextureSurface(w,h)) {
                                String nativeResult = hevc(consumer.surface,selected,decoder,variant);
                                if (!nativeResult.startsWith("PASS:")) throw new IllegalStateException(nativeResult);
                                if (variant == 0) consumer.checkRedPixels();
                                else if (variant == 3) consumer.checkGreenPixels();
                                else consumer.checkBluePixels();
                                Log.i("PlayerRegression", "HEVC decoder=" + selected + " variant=" + variant + " " + nativeResult.substring(6));
                            }
                        }
                    }
                }
                for (String selected : decoders) for (boolean portrait : new boolean[]{false,true}) {
                    try (TextureSurface consumer=new TextureSurface(portrait?360:640,portrait?640:360)) {
                        Log.i("PlayerRegression", "Testing decoder: "+selected);
                        String nativeResult=decode(consumer.surface,selected,portrait);
                        if(!nativeResult.startsWith("PASS:"))throw new IllegalStateException(nativeResult);
                        consumer.checkRedPixels();
                    }
                }
                for (String selected : decoders) {
                    try (TextureSurface consumer = new TextureSurface(640,360)) {
                        Log.i("PlayerRegression", "Testing sender resume: "+selected);
                        String nativeResult = resume(consumer.surface,selected);
                        if (!nativeResult.startsWith("PASS:")) throw new IllegalStateException(nativeResult);
                        consumer.checkBluePixels();
                    }
                }
                result = "PASS: available HEVC Surface fixtures, reset and codec switch, H.264 decoder buffering/B-frame ordering, regular/burst frame pacing, landscape/portrait Surface pixels, NDK decoder/reset, sender pause/resume blue pixels, continuous audio clock, shared audio PCM, AAudio/AudioTrack silent consumption/restart, open/timeout fallback, forced/sticky selection, stop races, short writes/write errors, route reopen, playback head wrap/restart";
            } catch (Throwable error) { result="FAIL: "+error; }
            Log.i("PlayerRegression", "COMPLETE: " + result);
            final String text=result; runOnUiThread(() -> label.setText(text));
        },"NativePlaybackFixture").start();
    }
}
