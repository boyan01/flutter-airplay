// SPDX-License-Identifier: GPL-3.0-only
// Exercise the production receive callback bindings without a test-only player API.
#include "../player/player.cpp"
#include "resume_fixtures.h"
#include "audio_fixtures.h"
#include "audio_decoder_tests.h"
#include "video_fixtures.h"
#include "hevc_fixtures.h"
#include <stdexcept>
#ifdef __APPLE__
#include <CoreVideo/CoreVideo.h>
#endif

void check_video_resume(void *surface, const char *decoder) {
    struct Progress { std::atomic<int> frames{0}, pauses{0}, audio{0}, audio_stops{0}; std::atomic<bool> blue{false}; } progress;
    AirplayCallbacks cb{}; cb.context = &progress;
    cb.event = [](void *context, const char *type, const char *, int, int) {
        if (!strcmp(type, "playing")) static_cast<Progress *>(context)->frames.fetch_add(1);
        if (!strcmp(type, "paused")) static_cast<Progress *>(context)->pauses.fetch_add(1);
        if (!strcmp(type, "audio")) static_cast<Progress *>(context)->audio.fetch_add(1);
        if (!strcmp(type, "audio_stopped")) static_cast<Progress *>(context)->audio_stops.fetch_add(1);
    };
#ifdef __APPLE__
    cb.frame = [](void *context, void *frame) {
        auto image = static_cast<CVPixelBufferRef>(frame);
        CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
        auto *pixel = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(image));
        if (pixel && pixel[0] > 200 && pixel[1] < 30 && pixel[2] < 30)
            static_cast<Progress *>(context)->blue.store(true);
        CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    };
#endif
    auto p = std::make_unique<AirplayPlayer>(cb, surface, decoder, "");
    const auto receive = receiver_callbacks(p.get());
    if (!p->video->supports_hevc() && receive.video_set_codec(receive.cls, VIDEO_CODEC_H265) != -1)
        throw std::runtime_error("unsupported platform accepts HEVC input");
    float width = 640, height = 360;
    receive.video_report_size(receive.cls, &width, &height, nullptr, nullptr);
    auto feed = [&](int first, int end) {
        const auto start = realtime_ns();
        for (int i = first; i < end; ++i) {
            video_decode_struct data{};
            data.data = const_cast<uint8_t *>(resume_frames[i]); data.data_len = int(resume_sizes[i]);
            data.ntp_time_local = start + int64_t(i - first) * kSecond / 60;
            receive.video_process(receive.cls, nullptr, &data);
        }
    };
    auto wait = [&](int before) {
        const auto limit = monotonic_ns() + kSecond;
        while (progress.frames.load() <= before && monotonic_ns() < limit)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        return progress.frames.load() > before;
    };
    feed(0, 3);
    if (!wait(0)) throw std::runtime_error("video resume fixture has no initial image");
    std::this_thread::sleep_for(std::chrono::milliseconds(120));
    const auto audio_generation = p->pcm->generation();
    const auto media_time = realtime_ns();
    const auto deadline = p->timeline.deadline(media_time);
    const int16_t audio[] = {1000, -1000, 2000, -2000};
    p->pcm->write(audio, 2, deadline, audio_generation);
    const auto visible = progress.frames.load();
    receive.video_pause(receive.cls);
    if (progress.pauses.load() != 1) throw std::runtime_error("sender pause has no distinct UI event");
    feed(3, 4); // A queued inter frame still updates references while presentation is paused.
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    if (progress.frames.load() != visible)
        throw std::runtime_error("paused sender still presents video");
    const auto before = progress.frames.load();
    receive.video_resume(receive.cls);
    feed(4, 9); // Continue the same GOP without another IDR or configuration packet.
    if (!wait(before)) throw std::runtime_error("video input resumes but produces no image after sender pause");
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
#ifdef __APPLE__
    if (!progress.blue.load()) throw std::runtime_error("resumed video retains the old image");
#endif
    if (p->pcm->generation() != audio_generation)
        throw std::runtime_error("video pause flushes continuing audio");
    if (p->timeline.deadline(media_time) != deadline)
        throw std::runtime_error("video pause resets the shared media clock");
    int16_t sound[4]{}; p->pcm->read(sound, 2, deadline);
    if (!std::equal(std::begin(audio), std::end(audio), std::begin(sound)))
        throw std::runtime_error("video pause discards queued audio");
    audio_decode_struct packet{}; packet.ct = 4;
    const auto audio_start = realtime_ns();
    // System codecs can buffer initial AAC packets. The UI event must follow
    // actual PCM production and still fire only once for the continuing stream.
    for (int i = 0; i < 8; ++i) {
        packet.data = const_cast<uint8_t *>(i ? aac_1 : aac_0);
        packet.data_len = i ? sizeof(aac_1) : sizeof(aac_0);
        packet.ntp_time_local = audio_start + int64_t(i) * 1024 * kSecond / kSampleRate;
        receive.audio_process(receive.cls, nullptr, &packet);
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    if (progress.audio.load() != 1) throw std::runtime_error("decoded PCM has no single audio UI event");
    receive.audio_flush(receive.cls);
    if (progress.audio_stops.load() != 1) throw std::runtime_error("audio flush has no pause UI event");
}

#ifdef __APPLE__
void check_mac_hevc() {
    struct Progress {
        std::atomic<int> frames{0}, width{0}, height{0}, red{0}, green{0}, blue{0};
    } progress;
    AirplayCallbacks cb{}; cb.context = &progress;
    cb.frame = [](void *context, void *frame) {
        auto *p = static_cast<Progress *>(context);
        auto image = static_cast<CVPixelBufferRef>(frame);
        CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
        auto *pixel = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(image));
        if (pixel && CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA) {
            p->blue = pixel[0]; p->green = pixel[1]; p->red = pixel[2];
        }
        p->width = int(CVPixelBufferGetWidth(image)); p->height = int(CVPixelBufferGetHeight(image));
        CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
        ++p->frames;
    };
    auto p = std::make_unique<AirplayPlayer>(cb, nullptr, nullptr, nullptr);
    const auto receive = receiver_callbacks(p.get());
    if (!p->video->supports_hevc()) {
        if (receive.video_set_codec(receive.cls, VIDEO_CODEC_H265) != -1)
            throw std::runtime_error("Mac without HEVC hardware accepts HEVC input");
        std::puts("SKIP: Mac HEVC hardware is unavailable; receiver rejects HEVC");
        return;
    }
    if (receive.video_set_codec(receive.cls, VIDEO_CODEC_H265) != 0)
        throw std::runtime_error("Mac receiver rejects HEVC despite hardware support");
    auto feed = [&](const uint8_t *bytes, size_t count, int width, int height, int color) {
        const auto before = progress.frames.load();
        video_decode_struct data{};
        data.data = const_cast<uint8_t *>(bytes); data.data_len = int(count); data.ntp_time_local = realtime_ns();
        receive.video_process(receive.cls, nullptr, &data);
        const auto until = monotonic_ns() + kSecond;
        while (progress.frames == before && monotonic_ns() < until)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (progress.frames != before + 1 || progress.width != width || progress.height != height)
            throw std::runtime_error("Mac HEVC receive path has no correctly sized decoded image");
        const auto actual = color == 0 ? progress.red.load() : color == 1 ? progress.green.load() : progress.blue.load();
        if (actual < 200) throw std::runtime_error("Mac HEVC decoded color or BGRA conversion is incorrect");
    };
    feed(hevc_fixtures::landscape, sizeof(hevc_fixtures::landscape), 640, 360, 0);
    feed(hevc_fixtures::portrait, sizeof(hevc_fixtures::portrait), 360, 640, 2);
    feed(hevc_fixtures::uhd, sizeof(hevc_fixtures::uhd), 3840, 2160, 2);
    p->reset();
    feed(hevc_fixtures::main10, sizeof(hevc_fixtures::main10), 640, 360, 1);
    if (receive.video_set_codec(receive.cls, VIDEO_CODEC_UNKNOWN) != -1)
        throw std::runtime_error("Mac receiver accepts an unknown codec");
    if (receive.video_set_codec(receive.cls, VIDEO_CODEC_H264) != 0)
        throw std::runtime_error("Mac receiver cannot return to H.264");
    feed(landscape, sizeof(landscape), 640, 360, 0);
    std::puts("PASS: Mac HEVC receive callback, BGRA pixels, rotation, 4K, Main10, reset and H.264 reconnect");
}
void check_audio_unsynchronized_burst() {
    auto p = std::make_unique<AirplayPlayer>(AirplayCallbacks{}, nullptr, nullptr, nullptr);
    const auto receive = receiver_callbacks(p.get());
    const auto bytes = make_alac_packet(352);
    constexpr int packets = 32, frames = packets * 352;
    for (int session = 0; session < 3; ++session) {
        if (session) receive.audio_flush(receive.cls);
        const uint32_t first_rtp = session == 0 ? UINT32_MAX - 3 * 352 : session * 4 * kSampleRate;
        const auto pts = realtime_ns();
        int64_t first_due = 0;
        for (int i = 0; i < packets; ++i) {
            audio_decode_struct data{};
            data.ct = 2; data.data = const_cast<uint8_t *>(bytes.data()); data.data_len = int(bytes.size());
            data.rtp_time = first_rtp + i * 352;
            // No NTP response: packets still carry a continuous RTP sample clock.
            data.ntp_time_local = session == 2 ? pts + int64_t(i) * 352 * kSecond / kSampleRate : 0;
            const auto before = monotonic_ns();
            receive.audio_process(receive.cls, nullptr, &data);
            if (!i) first_due = session == 2 ? p->timeline.deadline(pts) : before + p->audio_lead_ms.load() * 1000000;
        }
        const auto late_before = p->pcm->late_drops();
        std::vector<int16_t> output(frames * 2);
        p->pcm->read(output.data(), frames, first_due);
        const auto nonzero = std::count_if(output.begin(), output.end(), [](auto sample) { return sample != 0; }) / 2;
        const auto late = p->pcm->late_drops() - late_before;
        std::printf("Audio RTP burst: session=%d nonzero=%zu/%d late=%llu\n", session, nonzero, frames,
            static_cast<unsigned long long>(late));
        if (nonzero < frames - 100 || late > 100)
            throw std::runtime_error("unsynchronized audio burst cuts continuous PCM");
    }
}
void check_mac_decode_ahead() {
    std::atomic<int> frames{0};
    AirplayCallbacks cb{}; cb.context = &frames;
    cb.event = [](void *context, const char *type, const char *, int, int) {
        if (!strcmp(type, "playing")) static_cast<std::atomic<int> *>(context)->fetch_add(1);
    };
    auto p = std::make_unique<AirplayPlayer>(cb, nullptr, nullptr, nullptr);
    auto receive = receiver_callbacks(p.get());
    auto feed = [&](int64_t pts) {
        video_decode_struct data{};
        data.data = const_cast<uint8_t *>(landscape); data.data_len = sizeof(landscape);
        data.ntp_time_local = pts;
        receive.video_process(receive.cls, nullptr, &data);
    };
    feed(realtime_ns());
    auto until = monotonic_ns() + 300000000;
    while (!frames && monotonic_ns() < until) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    if (!frames) throw std::runtime_error("Mac warmup produces no frame");
    const auto baseline = frames.load();
    const auto pts = realtime_ns() + 100000000;
    const auto first_due = p->timeline.deadline(pts);
    for (int i = 0; i < 9; ++i) feed(pts + i * kSecond / 60);
    until = first_due - 30000000;
    while (monotonic_ns() < until) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    {
        std::lock_guard<std::mutex> guard(p->lock);
        if (!p->packets.empty()) throw std::runtime_error("Mac presentation wait blocks burst decoding");
    }
    if (frames != baseline) throw std::runtime_error("Mac presents a future frame early");
    until = first_due + 9 * kSecond / 60 + 50000000;
    while (frames < baseline + 9 && monotonic_ns() < until) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    if (frames != baseline + 9) throw std::runtime_error("Mac burst loses scheduled frames");
    const auto before_reset = frames.load();
    const auto future_pts = realtime_ns() + 200000000;
    const auto cancelled_due = p->timeline.deadline(future_pts);
    for (int i = 0; i < 6; ++i) feed(future_pts + i * kSecond / 60);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    p->reset(); feed(realtime_ns());
    until = cancelled_due + 6 * kSecond / 60 + 50000000;
    while (monotonic_ns() < until) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    if (frames != before_reset + 1) throw std::runtime_error("Mac reset retains cancelled frames or loses fresh output");
    std::puts("PASS: Mac decodes nine-frame burst ahead, schedules every frame, and cancels pending output on reset");
}
void check_mac_arrival_jitter() {
    struct Progress { std::mutex lock; std::vector<int64_t> times; } progress;
    AirplayCallbacks cb{}; cb.context = &progress;
    cb.event = [](void *context, const char *type, const char *, int, int) {
        if (strcmp(type, "playing")) return;
        auto *progress = static_cast<Progress *>(context);
        std::lock_guard<std::mutex> guard(progress->lock);
        progress->times.push_back(monotonic_ns());
    };
    auto p = std::make_unique<AirplayPlayer>(cb, nullptr, nullptr, nullptr);
    const auto receive = receiver_callbacks(p.get());
    constexpr int count = 84;
    constexpr int64_t period = kSecond / 60;
    const auto start = monotonic_ns(), pts = realtime_ns();
    const auto first_due = p->timeline.deadline(pts);
    int sent = 0;
    while (monotonic_ns() < first_due + count * period + 200000000) {
        // Model an ordered TCP stream: frame 16 is delayed 100ms, and the
        // following frames arrive together after that delay clears.
        while (sent < count) {
            const auto arrival = sent >= 16 && sent <= 22
                ? start + 16 * period + 100000000 : start + sent * period;
            if (monotonic_ns() < arrival) break;
            video_decode_struct data{};
            data.data = const_cast<uint8_t *>(landscape); data.data_len = sizeof(landscape);
            data.ntp_time_local = pts + sent * period;
            receive.video_process(receive.cls, nullptr, &data);
            ++sent;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::lock_guard<std::mutex> guard(progress.lock);
    int64_t max_gap = 0;
    for (size_t i = 10; i < progress.times.size(); ++i)
        max_gap = std::max(max_gap, progress.times[i] - progress.times[i - 1]);
    std::printf("Mac arrival jitter: presented=%zu/%d maxGapMs=%.2f\n", progress.times.size(), count, max_gap / 1e6);
    if (progress.times.size() != count || max_gap > 30000000)
        throw std::runtime_error("Mac arrival jitter produces a presentation stall");
}
int main() {
    try { check_mac_hevc(); check_audio_unsynchronized_burst(); check_video_resume(nullptr, nullptr); check_mac_decode_ahead(); check_mac_arrival_jitter(); std::puts("PASS: sender video pause/resume, continuing audio and media clock"); }
    catch (const std::exception &error) { std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1; }
}
#else
#include <jni.h>
#include <android/native_window_jni.h>
#include "video_fixtures.h"

extern "C" JNIEXPORT jstring JNICALL Java_tech_soit_flutterairplay_player_1regression_TestActivity_switchSurface(
        JNIEnv *env, jobject, jobject first, jobject second, jstring decoder, jobject a, jobject b) {
    auto *first_window = ANativeWindow_fromSurface(env, first);
    auto *second_window = ANativeWindow_fromSurface(env, second);
    const char *name = env->GetStringUTFChars(decoder, nullptr);
    std::string result;
    try {
        auto p = std::make_unique<AirplayPlayer>(AirplayCallbacks{}, first_window, name, "");
        auto receive = receiver_callbacks(p.get());
        float w = 640, h = 360;
        receive.video_report_size(receive.cls, &w, &h, nullptr, nullptr);
        auto feed = [&](int begin, int end, jobject consumer) {
            const auto pts = realtime_ns();
            for (int i = begin; i < end; ++i) {
                video_decode_struct data{};
                data.data = const_cast<uint8_t *>(resume_frames[i]);
                data.data_len = int(resume_sizes[i]);
                data.ntp_time_local = pts + int64_t(i-begin) * kSecond / 60;
                receive.video_process(receive.cls, nullptr, &data);
            }
            auto sample = env->GetMethodID(env->GetObjectClass(consumer), "sampleTimestamp", "()J");
            const auto until = monotonic_ns() + 350000000;
            while (monotonic_ns() < until) {
                env->CallLongMethod(consumer, sample);
                if (env->ExceptionCheck()) throw std::runtime_error("Surface consumer failed");
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            auto check = env->GetMethodID(env->GetObjectClass(consumer), begin == 0 ? "checkRedPixels" : "checkBluePixels", "()V");
            env->CallVoidMethod(consumer, check);
            if (env->ExceptionCheck()) throw std::runtime_error("Surface switch lost decoded pixels");
        };
        feed(0,3,a);
        const auto pts = realtime_ns(), due = p->timeline.deadline(pts);
        const auto generation = p->pcm->generation();
        if (!airplay_player_set_surface(p.get(), second_window)) throw std::runtime_error("Cannot switch to background surface");
        feed(3,6,b);
        if (!airplay_player_set_surface(p.get(), first_window)) throw std::runtime_error("Cannot restore visible surface");
        feed(6,9,a); // No new SPS or IDR: decoder references must survive both switches.
        if (generation != p->pcm->generation() || due != p->timeline.deadline(pts))
            throw std::runtime_error("Surface switch resets audio or media clock");
        result = "PASS: surface switch and return, inter-frame blue pixels, preserved media clock";
    } catch (const std::exception &error) { result = std::string("FAIL: ") + error.what(); }
    env->ReleaseStringUTFChars(decoder, name);
    ANativeWindow_release(first_window); ANativeWindow_release(second_window);
    return env->ExceptionCheck() ? nullptr : env->NewStringUTF(result.c_str());
}

extern "C" JNIEXPORT jstring JNICALL Java_tech_soit_flutterairplay_player_1regression_PacingTest_run(
        JNIEnv *env, jclass, jobject surface, jstring decoder, jobject consumer, jint batch, jint refresh_hz, jint phase_ms) {
    auto sample = env->GetMethodID(env->GetObjectClass(consumer), "sampleTimestamp", "()J");
    if (!sample) return nullptr;
    auto *window = ANativeWindow_fromSurface(env, surface);
    const char *name = env->GetStringUTFChars(decoder, nullptr);
    std::string result;
    try {
        auto p = std::make_unique<AirplayPlayer>(AirplayCallbacks{}, window, name, "");
        const auto receive = receiver_callbacks(p.get());
        float width = landscape_width, height = landscape_height;
        receive.video_report_size(receive.cls, &width, &height, nullptr, nullptr);
        auto feed = [&](int64_t pts) {
            video_decode_struct data{};
            data.data = const_cast<uint8_t *>(landscape); data.data_len = sizeof(landscape);
            data.ntp_time_local = pts;
            receive.video_process(receive.cls, nullptr, &data);
        };
        constexpr int64_t period = kSecond / 60;
        const auto warmup = realtime_ns();
        for (int i = 0; i < 6; ++i) feed(warmup + i * period);
        auto until = monotonic_ns() + 250000000;
        while (monotonic_ns() < until) {
            env->CallLongMethod(consumer, sample);
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }

        const auto start = monotonic_ns(), pts = realtime_ns();
        const auto first_due = p->timeline.deadline(pts);
        int sent = 0, consumed = 0, early = 0;
        int64_t last_pts = 0, last_latch = 0, max_gap = 0, max_early = 0;
        auto next_sample = start + int64_t(phase_ms) * 1000000;
        while (monotonic_ns() < start + 1400000000) {
            const auto now = monotonic_ns();
            // The padding keeps software codecs from retaining the measured tail.
            if (sent < 66 && now >= start + sent * period) {
                for (int b = 0; b < batch && sent < 66; ++b, ++sent) feed(pts + sent * period);
            }
            if (now >= next_sample) {
                const auto timestamp = env->CallLongMethod(consumer, sample);
                const auto latch = monotonic_ns();
                if (timestamp != last_pts && timestamp >= first_due / 1000 * 1000 &&
                    timestamp < (first_due + 60 * period) / 1000 * 1000) {
                    ++consumed;
                    if (timestamp > latch + 2000000) ++early;
                    max_early = std::max(max_early, int64_t(timestamp - latch));
                    if (last_latch) max_gap = std::max(max_gap, latch - last_latch);
                    last_latch = latch; last_pts = timestamp;
                }
                next_sample += kSecond / refresh_hz;
                if (next_sample <= latch) next_sample = latch + kSecond / refresh_hz;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        char summary[256];
        snprintf(summary, sizeof(summary), "%s batch=%d refresh=%d phase_ms=%d consumed=%d/60 early=%d maxEarlyMs=%.2f maxGapMs=%.2f",
            !early && consumed >= 58 && max_gap < 42000000 ? "PACING_OK:" : "FAIL:",
            batch, refresh_hz, phase_ms, consumed, early, double(max_early) / 1e6, double(max_gap) / 1e6);
        result = summary;
        if (batch == 9 && !early && consumed >= 58) {
            // Reset while decoded output is held for a future deadline. A new
            // codec must neither release an old index nor display the old frame.
            const auto future_pts = realtime_ns() + 500000000;
            const auto cancelled_due = p->timeline.deadline(future_pts) / 1000 * 1000;
            for (int i = 0; i < 4; ++i) feed(future_pts + i * period);
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            p->reset();
            const auto fresh_pts = realtime_ns();
            const auto fresh_due = p->timeline.deadline(fresh_pts) / 1000 * 1000;
            for (int i = 0; i < 6; ++i) feed(fresh_pts + i * period);
            bool fresh_image = false;
            while (monotonic_ns() < cancelled_due + 4 * period + 50000000) {
                const auto timestamp = env->CallLongMethod(consumer, sample);
                if (timestamp >= cancelled_due && timestamp < cancelled_due + 4 * period)
                    throw std::runtime_error("reset displays a cancelled future frame");
                fresh_image |= timestamp >= fresh_due && timestamp < fresh_due + 6 * period;
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            if (!fresh_image) throw std::runtime_error("reset of pending output prevents fresh video");
            result += " pendingReset=ok";
        }
    } catch (const std::exception &error) { result = std::string("FAIL: ") + error.what(); }
    env->ReleaseStringUTFChars(decoder, name); ANativeWindow_release(window);
    if (env->ExceptionCheck()) return nullptr;
    return env->NewStringUTF(result.c_str());
}

extern "C" JNIEXPORT jstring JNICALL Java_tech_soit_flutterairplay_player_1regression_TestActivity_resume(
        JNIEnv *env, jobject, jobject surface, jstring decoder) {
    auto *window = ANativeWindow_fromSurface(env, surface);
    const char *name = env->GetStringUTFChars(decoder, nullptr);
    std::string result;
    try { check_video_resume(window, name); result = "PASS: sender video pause/resume"; }
    catch (const std::exception &error) { result = std::string("FAIL: ") + error.what(); }
    env->ReleaseStringUTFChars(decoder, name); ANativeWindow_release(window);
    return env->NewStringUTF(result.c_str());
}

#include "reorder_fixtures.h"
extern "C" JNIEXPORT jstring JNICALL Java_tech_soit_flutterairplay_player_1regression_ReorderTest_run(
        JNIEnv *env, jclass, jobject surface, jstring decoder, jobject consumer, jboolean bframes) {
    using namespace reorder_fixtures;
    auto sample = env->GetMethodID(env->GetObjectClass(consumer), "sampleTimestamp", "()J");
    if (!sample) return nullptr;
    auto *window = ANativeWindow_fromSurface(env, surface);
    const char *name = env->GetStringUTFChars(decoder, nullptr);
    std::string result;
    try {
        auto p = std::make_unique<AirplayPlayer>(AirplayCallbacks{}, window, name, "");
        const auto receive = receiver_callbacks(p.get());
        float width = bframes ? 640 : 2560, height = bframes ? 360 : 1440;
        receive.video_report_size(receive.cls, &width, &height, nullptr, nullptr);
        const auto *bytes = bframes ? bframes_data : unrestricted_data;
        const auto *packets = bframes ? bframes_packets : unrestricted_packets;
        const int64_t period = kSecond / (bframes ? 60 : 30);
        const auto start = monotonic_ns(), pts = realtime_ns();
        const auto first_due = p->timeline.deadline(pts);
        int sent = 0, consumed = 0, early = 0, backwards = 0;
        int64_t last_pts = 0, last_latch = 0, max_gap = 0, next_sample = start;
        while (monotonic_ns() < start + 96 * period + 300000000) {
            const auto now = monotonic_ns();
            if (sent < 96 && now >= start + sent * period) {
                const auto &packet = packets[sent++];
                video_decode_struct data{};
                data.data = const_cast<uint8_t *>(bytes + packet[0]); data.data_len = packet[1];
                // Packet order is decode order; NTP timestamps are presentation order.
                data.ntp_time_local = pts + packet[2] * period;
                receive.video_process(receive.cls, nullptr, &data);
            }
            if (now >= next_sample) {
                const auto timestamp = env->CallLongMethod(consumer, sample);
                const auto latch = monotonic_ns();
                // Ignore startup and give the decoder enough padding at the end.
                if (timestamp != last_pts && timestamp >= (first_due + 16 * period) / 1000 * 1000 &&
                    timestamp < (first_due + 76 * period) / 1000 * 1000) {
                    ++consumed;
                    if (timestamp > latch + 2000000) ++early;
                    if (last_pts && timestamp < last_pts) ++backwards;
                    if (last_latch) max_gap = std::max(max_gap, int64_t(latch - last_latch));
                    last_latch = latch; last_pts = timestamp;
                }
                next_sample = now + kSecond / 120;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        char summary[256];
        snprintf(summary, sizeof(summary), "%s %s consumed=%d/60 early=%d backwards=%d maxGapMs=%.2f",
            consumed >= 58 && !early && !backwards && max_gap < period + 25000000 ? "ORDER_OK:" : "FAIL:",
            bframes ? "B-frames" : "1440p30 unrestricted POC", consumed, early, backwards, double(max_gap) / 1e6);
        result = summary;
    } catch (const std::exception &error) { result = std::string("FAIL: ") + error.what(); }
    env->ReleaseStringUTFChars(decoder, name); ANativeWindow_release(window);
    if (env->ExceptionCheck()) return nullptr;
    return env->NewStringUTF(result.c_str());
}
#endif
