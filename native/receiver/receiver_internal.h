// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "json.h"
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace airplay {
// One copied event outlet. The receiver owns its lifetime and closes it after
// draining its worker; adapters own transport and subscriptions.
struct ReceiverObserver {
    virtual ~ReceiverObserver() = default;
    virtual void deliver(const std::string& bytes) = 0;
    virtual void close() = 0;
};
bool observe_receiver(uint64_t handle, std::shared_ptr<ReceiverObserver> observer);
Json control_receiver(uint64_t handle, const std::string& request);
bool enqueue_receiver(uint64_t handle, std::function<void()> task);
}  // namespace airplay
