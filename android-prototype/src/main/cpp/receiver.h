// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <deque>
#include <mutex>
#include <vector>
extern "C" {
#include "raop.h"
}
namespace airplay {
struct Packet {
    int kind = 0; // 1 video, 2 audio; compressed elementary data, never decoded pixels.
    int codec = 0; // video: 1 AVC, 2 HEVC; audio: UxPlay ct.
    uint64_t pts = 0; // UxPlay local NTP nanoseconds; not Android monotonic time.
    uint32_t rtp = 0;
    int sync = 0;
    uint64_t epoch = 0;
    std::vector<uint8_t> bytes;
};
class Receiver {
public:
    Receiver() = default;
    ~Receiver();
    Receiver(const Receiver &) = delete;
    Receiver &operator=(const Receiver &) = delete;
    int start(const char *name, const uint8_t identity[6], const char *keyfile);
    void stop();
    std::vector<uint8_t> txt(bool audio) const;
    bool poll(Packet &packet);
    void enqueue(Packet packet);
    void flush();
    uint64_t dropped();
    uint64_t epoch();
private:
    raop_t *raop_ = nullptr;
    dnssd_t *dns_ = nullptr;
    std::mutex mutex_;
    std::deque<Packet> queue_;
    size_t queuedBytes_ = 0;
    uint64_t epoch_ = 0, dropped_ = 0;
};
}
