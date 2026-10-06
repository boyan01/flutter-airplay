// SPDX-License-Identifier: GPL-3.0-only
// Exercise the production receive callback bindings without a test-only player API.
#include "../../native/playback/player_internal.h"
#include "../../native/protocol/uxplay_callbacks.h"
#include "../../native/tests/fixtures/resume_fixtures.h"
#include "../../native/tests/fixtures/audio_fixtures.h"
#include <stdexcept>
#include "../../native/backends/linux/linux_video.h"

void check_video_resume(void *surface, const char *decoder) {
    struct Progress { std::atomic<int> frames{0}, pauses{0}, audio{0}, audio_stops{0}; std::atomic<bool> blue{false}; } progress;
    AirplayCallbacks cb{}; cb.context = &progress;
    cb.event = [](void *context, const char *type, const char *, int, int) {
        if (!strcmp(type, "playing")) static_cast<Progress *>(context)->frames.fetch_add(1);
        if (!strcmp(type, "paused")) static_cast<Progress *>(context)->pauses.fetch_add(1);
        if (!strcmp(type, "audio")) static_cast<Progress *>(context)->audio.fetch_add(1);
        if (!strcmp(type, "audio_stopped")) static_cast<Progress *>(context)->audio_stops.fetch_add(1);
    };
    cb.frame = [](void *context, void *frame) {
        auto *image = static_cast<AirplayLinuxVideoFrame *>(frame);
        auto *pixel = image->data;
        if (pixel && pixel[2] > 200 && pixel[1] < 30 && pixel[0] < 30)
            static_cast<Progress *>(context)->blue.store(true);
    };
    auto p = std::make_unique<AirplayPlayer>(cb, surface, decoder, "");
    const auto receive = receiver_callbacks(p.get());
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
    if (!progress.blue.load()) throw std::runtime_error("resumed video retains the old image");
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

int main() {
    try { check_video_resume(nullptr, nullptr); std::puts("PASS: Linux sender video pause/resume, changed pixels, continuing audio and media clock"); }
    catch (const std::exception &error) { std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1; }
}
