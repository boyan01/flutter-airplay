// SPDX-License-Identifier: GPL-3.0-only
#include "../../playback/alac_decoder.h"
#include "audio_decoder_tests.h"
#include <cstdio>
#include <random>
int main() {
    using airplay::AlacDecoder;
    try {
        std::vector<int16_t> pcm;
        AlacDecoder short_frames;
        if (!short_frames.open(352)) throw std::runtime_error("ALAC 352 configuration");
        auto packet = make_alac_packet(352);
        if (!short_frames.decode(packet.data(), packet.size(), pcm) || pcm.size() != 704)
            throw std::runtime_error("ALAC 352 decode");
        for (int i = 0; i < 352; ++i) if (pcm[i * 2] != 1000 + i || pcm[i * 2 + 1] != -1000 - i)
            throw std::runtime_error("ALAC PCM is not bit-exact");
        for (uint32_t frames : {0u, 353u, 65535u, UINT32_MAX}) {
            packet = make_alac_packet(frames, false);
            if (short_frames.decode(packet.data(), packet.size(), pcm)) throw std::runtime_error("oversized ALAC frame accepted");
        }
        AlacDecoder decoder;
        if (!decoder.open(4096) || !decoder.decode(alac_0, sizeof(alac_0), pcm) || pcm.size() != 8192)
            throw std::runtime_error("compressed ALAC 4096 decode");
        for (size_t size = 1; size < sizeof(alac_0) / 2; ++size)
            if (decoder.decode(alac_0, size, pcm)) throw std::runtime_error("truncated ALAC accepted");
        std::mt19937 random(1);
        for (int i = 0; i < 10000; ++i) {
            std::vector<uint8_t> input(1 + random() % 128);
            for (auto &byte : input) byte = random();
            decoder.decode(input.data(), input.size(), pcm);
        }
        if (!decoder.decode(alac_0, sizeof(alac_0), pcm)) throw std::runtime_error("ALAC does not recover after malformed input");
        std::puts("PASS: bit-exact ALAC 352, compressed ALAC 4096, oversized/truncated frames, 10000 deterministic malformed packets and recovery");
    } catch (const std::exception &error) { std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1; }
}
