// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <vector>
extern "C" {
#include "raop.h"
}
namespace airplay {
class Receiver {
public:
    Receiver() = default;
    ~Receiver();
    Receiver(const Receiver &) = delete;
    Receiver &operator=(const Receiver &) = delete;
    int start(const char *name, const uint8_t identity[6], const char *keyfile);
    void stop();
    std::vector<uint8_t> txt(bool audio) const;
private:
    raop_t *raop_ = nullptr;
    dnssd_t *dns_ = nullptr;
};
}
