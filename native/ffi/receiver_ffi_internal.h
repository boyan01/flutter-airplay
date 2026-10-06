// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../include/airplay/receiver_ffi.h"
#include "../receiver/receiver_internal.h"
#include <functional>
#include <memory>
#include <string>

namespace airplay {
// Transport state is separate from receiver state; the worker only emits copied events.
class ReceiverChannel final : public ReceiverObserver {
public:
    ReceiverChannel();
    ~ReceiverChannel();
    uint64_t attach(int64_t port, void* post);
    bool detach(uint64_t token);
    bool submit(uint64_t handle, uint64_t token, int64_t request, std::function<Json()> action);
    void deliver(const std::string& bytes) override;
    void close() override;
private:
    struct Impl;
    std::shared_ptr<Impl> impl_;
};
std::shared_ptr<ReceiverChannel> receiver_channel(uint64_t handle);
}  // namespace airplay
