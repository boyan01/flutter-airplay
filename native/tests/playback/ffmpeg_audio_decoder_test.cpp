// SPDX-License-Identifier: GPL-3.0-only
#include "audio_decoder_tests.h"
#include <cstdio>
#include <string>

namespace {
using namespace airplay;

void check(bool condition, const char *description) {
    if (!condition) throw std::runtime_error(description);
}

bool has_signal(const std::vector<int16_t> &pcm) {
    return std::any_of(pcm.begin(), pcm.end(), [](int16_t value) { return std::abs(int(value)) > 50; });
}

void check_malformed_recovery() {
    const uint8_t malformed[] = {0xff, 0xff, 0xff};
    const auto alac = make_alac_packet(352);
    struct Fixture { int ct, frames; const uint8_t *data; size_t size; };
    const Fixture fixtures[] = {
        {2, 352, alac.data(), alac.size()},
        {4, 1024, aac_1, sizeof(aac_1)},
        {8, 512, eld_1, sizeof(eld_1)},
        {8, 480, eld_480_1, sizeof(eld_480_1)},
    };
    for (const auto &fixture : fixtures) {
        auto buffer = std::make_shared<AudioBuffer>();
        bool malformed_logged = false;
        AudioDecoder decoder(buffer, [&](const char *message) {
            if (std::string(message).find("resetting decoder") != std::string::npos) malformed_logged = true;
        });
        decoder.format(fixture.ct, fixture.frames);
        const int64_t due = 1000000000;
        bool produced = true;
        check(!decoder.decode(malformed, sizeof(malformed), fixture.ct, due, &produced)
            && !produced, "malformed packet accepted or reported PCM");
        check(malformed_logged, "malformed packet did not produce a diagnostic");
        check(decoder.decode(fixture.data, fixture.size, fixture.ct, due, &produced)
            && produced, "decoder did not recover after malformed input");
        std::vector<int16_t> pcm(size_t(fixture.frames) * 2);
        buffer->read(pcm.data(), fixture.frames, due);
        check(has_signal(pcm), "malformed recovery did not produce non-silent PCM samples");

        check(decoder.decode(fixture.data, fixture.size, fixture.ct, due, &produced)
            && produced, "pre-FLUSH packet failed");
        const auto previous_generation = buffer->generation();
        decoder.flush();
        check(buffer->generation() != previous_generation, "FLUSH did not advance PCM generation");
        buffer->read(pcm.data(), fixture.frames, due);
        check(std::all_of(pcm.begin(), pcm.end(), [](auto value) { return value == 0; }),
            "FLUSH leaked old-generation PCM");
        check(decoder.decode(fixture.data, fixture.size, fixture.ct, due, &produced)
            && produced, "decoder did not recover after FLUSH");
        buffer->read(pcm.data(), fixture.frames, due);
        check(has_signal(pcm), "new-generation PCM was discarded after FLUSH");

        check(!decoder.decode(fixture.data, 1, fixture.ct, due, &produced)
            && !produced, "truncated packet accepted or reported PCM");
        buffer->read(pcm.data(), fixture.frames, due);
        check(std::all_of(pcm.begin(), pcm.end(), [](auto value) { return value == 0; }),
            "truncated packet left partial PCM in the queue");
        check(decoder.decode(fixture.data, fixture.size, fixture.ct, due, &produced)
            && produced, "decoder did not recover after truncation");
        buffer->read(pcm.data(), fixture.frames, due);
        check(has_signal(pcm), "truncation recovery did not produce PCM samples");
    }
}

void check_saturation_and_reconfiguration() {
    auto buffer = std::make_shared<AudioBuffer>(16);
    AudioDecoder decoder(buffer, [](const char *) {});
    decoder.format(4, 1024);
    const int64_t due = 1000000000;
    bool produced = false;
    check(decoder.decode(aac_1, sizeof(aac_1), 4, due, &produced) && produced,
        "partially accepted packet did not report PCM");
    check(decoder.decode(aac_1, sizeof(aac_1), 4, due, &produced) && !produced,
        "full PCM queue incorrectly reported produced audio");

    decoder.format(4, 123);
    check(!decoder.decode(aac_1, sizeof(aac_1), 4, due, &produced) && !produced,
        "invalid AAC frame length accepted");
    decoder.format(4, 1024);
    decoder.flush();
    // The output consumer, rather than FLUSH, owns reclamation of ring slots.
    int16_t pcm[32]{};
    buffer->read(pcm, 16, due);
    check(std::all_of(std::begin(pcm), std::end(pcm), [](auto value) { return value == 0; }),
        "saturated queue retained old-generation audio");
    check(decoder.decode(aac_1, sizeof(aac_1), 4, due, &produced) && produced,
        "decoder did not recover after invalid format and a saturated queue");

    const uint8_t byte = 0;
    check(!decoder.decode(&byte, 65537, 4, due, &produced) && !produced,
        "oversized packet accepted");
    check(!decoder.decode(&byte, 0, 4, due, &produced) && !produced,
        "empty packet accepted");
}

void check_output_format_recovery() {
    // One synthetic AAC-LC silence AU with an ADTS header signaling 48 kHz mono.
    // Generated with FFmpeg 7.1.5, taking a packet after the encoder-tag packet:
    // ffmpeg -f lavfi -i anullsrc=r=48000:cl=mono -frames:a 2 -c:a aac -f adts silence.aac
    // The complete 11-byte packet also decodes normally with FFmpeg by itself.
    // No recorded media or external runtime fixture generator is required.
    constexpr uint8_t wrong_format[] = {
        0xff, 0xf1, 0x4c, 0x40, 0x01, 0x7f, 0xfc, 0x01, 0x18, 0x20, 0x07,
    };
    auto buffer = std::make_shared<AudioBuffer>();
    bool format_rejected = false;
    AudioDecoder decoder(buffer, [&](const char *message) {
        if (std::string(message).find("Unsupported or corrupt FFmpeg AAC output") != std::string::npos)
            format_rejected = true;
    });
    bool produced = true;
    const int64_t due = 1000000000;
    check(!decoder.decode(wrong_format, sizeof(wrong_format), 4, due, &produced) && !produced,
        "48 kHz mono AAC output accepted");
    // Require the output-format check, rather than a generic bad-packet error.
    check(format_rejected, "wrong-format fixture did not reach PCM validation");
    std::vector<int16_t> pcm(2048, 1);
    buffer->read(pcm.data(), 1024, due);
    check(std::all_of(pcm.begin(), pcm.end(), [](auto value) { return value == 0; }),
        "rejected output format left PCM in the queue");
    check(decoder.decode(aac_1, sizeof(aac_1), 4, due, &produced) && produced,
        "decoder did not recover from output-format rejection");
    buffer->read(pcm.data(), 1024, due);
    check(has_signal(pcm), "output-format recovery did not produce PCM samples");
}
} // namespace

int main() {
    try {
        check_audio_decoder();
        check_malformed_recovery();
        check_saturation_and_reconfiguration();
        check_output_format_recovery();
        std::puts("PASS: AAC-LC/ELD and ALAC fixtures, deadlines, malformed/truncated input and recovery, "
            "FLUSH generations, saturated PCM queue, invalid configuration and output-format recovery");
    } catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
