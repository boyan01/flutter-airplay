// SPDX-License-Identifier: GPL-3.0-only
// AirPlay ALAC configuration derived from jqssun/android-airplay-server;
// see THIRD_PARTY_NOTICES.md and android/NOTICE.
#pragma once
#include <ALACDecoder.h>
#include <ALACBitUtilities.h>
#include <array>
#include <cstring>
#include <vector>

namespace airplay {
class AlacDecoder {
public:
    bool open(int frames) {
        if (frames <= 0 || frames > 16384) return false;
        std::array<uint8_t, 24> config{};
        config[0] = frames >> 24; config[1] = frames >> 16;
        config[2] = frames >> 8; config[3] = frames;
        config[5] = 16; config[6] = 40; config[7] = 10; config[8] = 14; config[9] = 2;
        config[11] = 255;
        config[22] = (44100 >> 8) & 255; config[23] = 44100 & 255;
        frames_ = frames;
        return decoder_.Init(config.data(), config.size()) == ALAC_noErr;
    }
    bool decode(const uint8_t *data, size_t size, std::vector<int16_t> &pcm) {
        if (!frames_ || !data || !size || size > 65536) return false;
        // The entropy reader uses up to five bytes of lookahead. Keep padding
        // allocated, but retain the real input length for truncation checks.
        input_.assign(size + 8, 0);
        std::memcpy(input_.data(), data, size);
        BitBuffer bits;
        BitBufferInit(&bits, input_.data(), uint32_t(size));
        pcm.resize(size_t(frames_) * 2);
        uint32_t frames = 0;
        if (decoder_.Decode(&bits, reinterpret_cast<uint8_t *>(pcm.data()), frames_, 2, &frames) != ALAC_noErr
            || !frames || frames > uint32_t(frames_)) return false;
        pcm.resize(size_t(frames) * 2);
        return true;
    }
private:
    ALACDecoder decoder_;
    std::vector<uint8_t> input_;
    int frames_ = 0;
};
} // namespace airplay
