// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../include/airplay/player.h"
#include <memory>

namespace airplay {
// Owns UxPlay, connection admission and discovery records. Media bytes are
// borrowed only during callbacks; playback copies queued video before return.
class ProtocolAdapter {
public:
    explicit ProtocolAdapter(AirplayPlayer& playback);
    ~ProtocolAdapter();
    bool start(const char* name, const uint8_t identity[6], const char* key, char* error, size_t capacity);
    bool started() const;
    uint16_t port() const;
    size_t txt(bool audio, uint8_t* output, size_t capacity) const;
    int connections() const;
    bool prepare_restart();
    void stop_receiver();
    void connected();
    void disconnected();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}  // namespace airplay
