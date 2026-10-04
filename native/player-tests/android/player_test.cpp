// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "android_audio.h"
#include <oboe/Oboe.h>
#include "audio_decoder.h"
#include "audio_clock_tests.h"
#include "audio_fixtures.h"
#include "audio_decoder_tests.h"
#include "video_fixtures.h"
#include <jni.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <thread>
#include <string>

extern "C" JNIEXPORT jstring JNICALL Java_tech_soit_flutterairplay_player_1regression_TestActivity_decode(
        JNIEnv *env, jobject, jobject surface, jstring decoder, jboolean portrait_mode) {
    using namespace airplay;
    try { check_audio_clock(); check_audio_decoder(); }
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
    return env->NewStringUTF("PASS: video restart, audio PCM/clock");
}

extern "C" JNIEXPORT jstring JNICALL Java_tech_soit_flutterairplay_player_1regression_TestActivity_audio(
        JNIEnv *env, jobject) {
    using namespace airplay;
    // Exercise both actual backends without emitting a test tone.
    if (!initialize_android_audio(env)) return env->NewStringUTF("FAIL: AudioTrack JNI setup");
    const auto check = [](bool ok, const char *message) { if (!ok) throw std::runtime_error(message); };
    try {
        for (int mode : {1, 2}) {
            auto buffer = std::make_shared<AudioBuffer>();
            auto output = make_android_audio_output(buffer, mode);
            const std::string backend = mode == 1 ? "actual=AAudio" : "actual=AudioTrack";
            for (int cycle = 0; cycle < 3; ++cycle) {
                check(output->start(), "forced backend start failed");
                // AAudio calibrates once when its initial device timestamp arrives.
                // Schedule after warmup to test steady PCM delivery, not that reset.
                const auto late_before = buffer->late_drops();
                std::vector<int16_t> silence(8820);
                check(buffer->write(silence.data(), 4410, monotonic_ns() + 500000000, buffer->generation()) == 4410,
                    "scheduled PCM queue write failed");
                std::this_thread::sleep_for(std::chrono::milliseconds(750));
                if (buffer->late_drops() - late_before >= 220) {
                    output->stop();
                    throw std::runtime_error("presentation estimate discarded scheduled PCM: " + output->diagnostics());
                }
                auto report = output->diagnostics();
                __android_log_print(ANDROID_LOG_INFO, "PlayerRegression", "%s", report.c_str());
                check(report.find(backend) != std::string::npos, "forced backend mismatch");
                check(report.find(" frames_total=0 ") == std::string::npos, "output consumer did not run");
                output->stop();
                const auto stopped = output->diagnostics();
                check(stopped.find("state=closed") != std::string::npos, "output did not stop");
                const auto frame_count = [](const std::string &text) {
                    const auto begin = text.find(" frames_total=");
                    return std::stoull(text.substr(begin + 14));
                };
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
                check(frame_count(stopped) == frame_count(output->diagnostics()), "consumer survived output stop");
            }
        }
        auto track = make_android_audio_output(std::make_shared<AudioBuffer>(), 2);
        check(track->start(), "short write AudioTrack start failed");
        android_audio_test_failure(*track, 0);
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        check(track->diagnostics().find("state=running") != std::string::npos, "partial writes stopped AudioTrack");
        android_audio_test_failure(*track, int(oboe::Result::ErrorInternal));
        const auto write_deadline = monotonic_ns() + kSecond;
        while (track->diagnostics().find("state=closed") == std::string::npos && monotonic_ns() < write_deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        check(track->diagnostics().find("write_errors=1") != std::string::npos, "write error was not reported");
        check(track->diagnostics().find("state=closed") != std::string::npos, "write error retained AudioTrack");
        track->stop();
        auto forced = make_android_audio_output(std::make_shared<AudioBuffer>(), 1);
        android_audio_test_failure(*forced, 0, true);
        check(!forced->start(), "forced AAudio open failure crossed backend");
        forced->stop();
        auto output = make_android_audio_output(std::make_shared<AudioBuffer>(), 0);
        android_audio_test_failure(*output, 0, true);
        check(output->start(), "open failure fallback did not start");
        check(output->diagnostics().find("actual=AudioTrack") != std::string::npos, "open failure did not fallback");
        output->stop();
        check(output->start(), "sticky compatibility restart failed");
        check(output->diagnostics().find("fallbacks=1") != std::string::npos, "fallback was repeated");
        output->stop();
        output = make_android_audio_output(std::make_shared<AudioBuffer>(), 0);
        check(output->start(), "auto AAudio start failed");
        android_audio_test_failure(*output, int(oboe::Result::ErrorTimeout));
        android_audio_test_failure(*output, int(oboe::Result::ErrorTimeout));
        auto report = output->diagnostics();
        check(report.find("actual=AudioTrack") != std::string::npos && report.find("fallbacks=1") != std::string::npos && report.find("state=running") != std::string::npos,
              "timeout fallback was absent or duplicated");
        output->stop();
        output = make_android_audio_output(std::make_shared<AudioBuffer>(), 0);
        check(output->start(), "route change start failed");
        android_audio_test_failure(*output, int(oboe::Result::ErrorDisconnected));
        check(output->diagnostics().find("actual=AAudio") != std::string::npos &&
              output->diagnostics().find("restarts=1") != std::string::npos, "route change did not reopen AAudio");
        android_audio_test_failure(*output, 0, true);
        android_audio_test_failure(*output, int(oboe::Result::ErrorDisconnected));
        check(output->diagnostics().find("actual=AudioTrack") != std::string::npos, "route reopen failure did not fallback");
        output->stop();
        output = make_android_audio_output(std::make_shared<AudioBuffer>(), 1);
        check(output->start(), "forced AAudio start failed");
        android_audio_test_failure(*output, int(oboe::Result::ErrorTimeout));
        check(output->diagnostics().find("fallbacks=0") != std::string::npos, "forced AAudio crossed backend");
        output->stop();
        for (int race = 0; race < 10; ++race) {
            output = make_android_audio_output(std::make_shared<AudioBuffer>(), 0);
            check(output->start(), "stop race start failed");
            std::thread error([&] { android_audio_test_failure(*output, int(oboe::Result::ErrorTimeout)); });
            output->stop(); error.join();
            check(output->diagnostics().find("state=closed") != std::string::npos, "error reopened stopped output");
        }
    } catch (const std::exception &error) {
        return env->NewStringUTF((std::string("FAIL: ") + error.what()).c_str());
    }
    return env->NewStringUTF("PASS: video restart, audio PCM/clock, AAudio/AudioTrack consumption/restart, open/timeout fallback, sticky selection, forced selection, stop races");
}
