// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "audio_decoder.h"
#include "audio_clock_tests.h"
#include "audio_fixtures.h"
#include "video_fixtures.h"
#include <jni.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <thread>
#include <string>

extern "C" JNIEXPORT jstring JNICALL Java_io_github_boyan01_player_1regression_TestActivity_decode(
        JNIEnv *env, jobject, jobject surface, jstring decoder, jboolean portrait_mode) {
    using namespace airplay;
    try { check_audio_clock(); }
    catch (const std::exception &error) { return env->NewStringUTF(error.what()); }
    auto *window = ANativeWindow_fromSurface(env, surface);
    const char *name = env->GetStringUTFChars(decoder, nullptr);
    int frames = 0, width = 0, height = 0;
    auto video = make_video_output(window, name, "", {
        [&](void *, int w, int h, int64_t, uint64_t generation) { if (generation == 7) { ++frames; width = w; height = h; } },
        [](const char *message) { __android_log_print(ANDROID_LOG_INFO, "PlayerRegression", "%s", message); }
    });
    ANativeWindow_release(window); env->ReleaseStringUTFChars(decoder, name);
    const int expected_width = portrait_mode ? landscape_height : landscape_width, expected_height = portrait_mode ? landscape_width : landscape_height;
    video->size(expected_width, expected_height);
    const auto *data = portrait_mode ? portrait : landscape;
    const auto size = portrait_mode ? sizeof(portrait) : sizeof(landscape);
    for (int session = 0; session < 2; ++session) {
        const int before = frames;
        for (int input = 0; input < 4; ++input) {
            if (!video->decode({{data, data+size}, monotonic_ns()+50000000+input*16666667, 7}))
                return env->NewStringUTF("FAIL: NDK input decode");
            video->drain();
        }
        const auto deadline = monotonic_ns()+2*kSecond;
        while (frames == before && monotonic_ns() < deadline) { video->drain(); std::this_thread::sleep_for(std::chrono::milliseconds(5)); }
        if (frames == before || width != expected_width || height != expected_height)
            return env->NewStringUTF(("FAIL: NDK output frames=" + std::to_string(frames) + " dimensions=" + std::to_string(width) + "x" + std::to_string(height)).c_str());
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        video->reset();
    }
    auto pcm = std::make_shared<AudioBuffer>();
    AudioDecoder audio(pcm, [](const char *) {});
    for (int ct : {2,4,8}) {
        pcm->flush(); audio.format(ct, ct == 2 ? 4096 : ct == 4 ? 1024 : 512);
        const auto *packet = ct == 2 ? alac_0 : ct == 4 ? aac_0 : eld_0;
        const auto length = ct == 2 ? sizeof(alac_0) : ct == 4 ? sizeof(aac_0) : sizeof(eld_0);
        const auto due = monotonic_ns();
        if (!audio.decode(packet, length, ct, due)) return env->NewStringUTF("FAIL: shared Android audio decode");
        std::vector<int16_t> sound((ct == 2 ? 4096 : ct == 4 ? 1024 : 512)*2);
        pcm->read(sound.data(), sound.size()/2, due);
        int peak = 0; for (auto sample : sound) peak = std::max(peak, std::abs(int(sample)));
        if (peak < 50) return env->NewStringUTF("FAIL: shared Android decoded PCM");
    }
    // Exercise the real device output without emitting the test tone.
    auto output = make_audio_output(std::make_shared<AudioBuffer>());
    if (!output->start()) return env->NewStringUTF("FAIL: Oboe device output start");
    output->stop();
    if (!output->start()) return env->NewStringUTF("FAIL: Oboe device output restart");
    output->stop();
    return env->NewStringUTF("PASS: NDK dimensions/keyframe/restart, continuous audio clock, AAC/ALAC/AAC-ELD PCM, Oboe start/restart");
}
