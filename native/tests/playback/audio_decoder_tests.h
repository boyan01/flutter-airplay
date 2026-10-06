// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../../playback/audio_decoder.h"
#include "../fixtures/audio_fixtures.h"
#include <stdexcept>
#include <string>
#include <thread>

// An uncompressed ALAC stereo element with a partial-frame length. This is a
// synthetic packet, independent of a third-party encoder or recorded media.
inline std::vector<uint8_t> make_alac_packet(uint32_t frames, bool samples = true) {
    std::vector<uint8_t> bytes;
    size_t position = 0;
    auto bits = [&](uint32_t value, unsigned count) {
        while (count) {
            if (position % 8 == 0) bytes.push_back(0);
            bytes.back() |= ((value >> --count) & 1) << (7 - position % 8);
            ++position;
        }
    };
    bits(1, 3); bits(0, 4); bits(0, 12); bits(1, 1); bits(0, 2); bits(1, 1); bits(frames, 32);
    if (samples) for (uint32_t i = 0; i < frames; ++i) { bits(uint16_t(1000 + i), 16); bits(uint16_t(-1000 - int(i)), 16); }
    bits(7, 3);
    return bytes;
}

inline void check_audio_decoder() {
    using namespace airplay;
    auto buffer = std::make_shared<AudioBuffer>();
    AudioDecoder decoder(buffer, [](const char *) {});
    const uint8_t invalid[] = {0xff, 0xff, 0xff};
    if (decoder.decode(invalid, sizeof(invalid), 99, 0) || decoder.decode(nullptr, 1, 2, 0))
        throw std::runtime_error("unsupported or empty audio accepted");
    const auto short_alac = make_alac_packet(352);
    struct Fixture { int ct, frames; const uint8_t *first; size_t first_size; const uint8_t *next; size_t next_size; };
    const Fixture fixtures[] = {
        {2, 4096, alac_0, sizeof(alac_0), alac_0, sizeof(alac_0)},
        {2, 352, short_alac.data(), short_alac.size(), short_alac.data(), short_alac.size()},
        {4, 1024, aac_0, sizeof(aac_0), aac_1, sizeof(aac_1)},
        {8, 512, eld_0, sizeof(eld_0), eld_1, sizeof(eld_1)},
        {8, 480, eld_480_0, sizeof(eld_480_0), eld_480_1, sizeof(eld_480_1)},
    };
    for (const auto &fixture : fixtures) {
        decoder.format(fixture.ct, fixture.frames);
        for (int session = 0; session < 2; ++session) {
            decoder.flush();
            const auto due = monotonic_ns();
            bool produced_any = false;
            for (int i = 0; i < 8; ++i) {
                bool produced = false;
                if (!decoder.decode(i ? fixture.next : fixture.first, i ? fixture.next_size : fixture.first_size,
                                    fixture.ct, due + int64_t(i) * fixture.frames * kSecond / kSampleRate, &produced))
                    throw std::runtime_error("audio decode failed: ct=" + std::to_string(fixture.ct) + " frames=" + std::to_string(fixture.frames));
                produced_any |= produced;
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            int16_t early[64]{};
            buffer->read(early, 32, due - 10000000);
            if (std::any_of(std::begin(early), std::end(early), [](auto value) { return value != 0; }))
                throw std::runtime_error("decoded PCM plays before its deadline");
            std::vector<int16_t> pcm(size_t(fixture.frames) * 8 * 2);
            buffer->read(pcm.data(), pcm.size() / 2, due);
            const auto active = std::count_if(pcm.begin(), pcm.end(), [](auto value) { return std::abs(int(value)) > 50; });
            if (!produced_any || active < fixture.frames * 2)
                throw std::runtime_error("missing scheduled PCM: ct=" + std::to_string(fixture.ct) + " frames=" + std::to_string(fixture.frames));
            decoder.flush(); buffer->read(pcm.data(), pcm.size() / 2, due);
            if (std::any_of(pcm.begin(), pcm.end(), [](auto value) { return value != 0; }))
                throw std::runtime_error("audio FLUSH retains old PCM");
        }
    }
}
