// SPDX-License-Identifier: GPL-3.0-only
#include "receiver_ffi_internal.h"
#include "../receiver/json.h"
#include <dart_native_api.h>
#include <atomic>
#include <map>
#include <mutex>

namespace airplay {
using PostObject = bool (*)(Dart_Port, Dart_CObject*);
std::shared_ptr<ReceiverChannel> receiver_channel(uint64_t handle) {
    static std::mutex lock;
    static std::map<uint64_t, std::weak_ptr<ReceiverChannel>> channels;
    std::lock_guard<std::mutex> guard(lock);
    for (auto it = channels.begin(); it != channels.end();) {
        if (it->second.expired()) it = channels.erase(it); else ++it;
    }
    if (auto found = channels.find(handle); found != channels.end()) return found->second.lock();
    auto channel = std::make_shared<ReceiverChannel>();
    if (!observe_receiver(handle, channel)) return nullptr;
    channels.emplace(handle, channel); return channel;
}
struct ReceiverChannel::Impl {
    std::mutex lock;
    uint64_t subscription = 0;
    Dart_Port port = 0;
    PostObject post = nullptr;
    bool closed = false;
    void deliver_locked(const std::string& bytes) {
        if (!port || !post) return;
        Dart_CObject object{}; object.type = Dart_CObject_kString; object.value.as_string = bytes.c_str();
        if (!post(port, &object)) { port = 0; post = nullptr; ++subscription; }
    }
};
ReceiverChannel::ReceiverChannel() : impl_(std::make_shared<Impl>()) {}
ReceiverChannel::~ReceiverChannel() = default;
uint64_t ReceiverChannel::attach(int64_t port, void* post) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    if (impl_->closed) return 0;
    impl_->port = port; impl_->post = reinterpret_cast<PostObject>(post); return ++impl_->subscription;
}
bool ReceiverChannel::detach(uint64_t token) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    if (impl_->closed || token != impl_->subscription) return false;
    impl_->port = 0; impl_->post = nullptr; ++impl_->subscription; return true;
}
void ReceiverChannel::close() {
    std::lock_guard<std::mutex> guard(impl_->lock);
    impl_->closed = true; impl_->port = 0; impl_->post = nullptr; ++impl_->subscription;
}
void ReceiverChannel::deliver(const std::string& bytes) {
    std::lock_guard<std::mutex> guard(impl_->lock); impl_->deliver_locked(bytes);
}
bool ReceiverChannel::submit(uint64_t handle, uint64_t token, int64_t request, std::function<Json()> action) {
    auto transport = impl_;
    { std::lock_guard<std::mutex> guard(transport->lock);
      if (transport->closed || !transport->port || token != transport->subscription) return false; }
    return enqueue_receiver(handle, [transport, token, request, action = std::move(action)] {
        { std::lock_guard<std::mutex> guard(transport->lock);
          if (transport->closed || token != transport->subscription) return; }
        auto completion = json_object(); set(completion.get(), "type", "complete"); set(completion.get(), "request", request);
        try { plist_dict_set_item(completion.get(), "data", action().release()); }
        catch (const std::exception& error) { set(completion.get(), "error", error.what()); }
        const auto bytes = json_text(completion.get());
        std::lock_guard<std::mutex> guard(transport->lock);
        if (transport->closed || token != transport->subscription) return;
        transport->deliver_locked(bytes);
    });
}
}  // namespace airplay
extern "C" uint32_t airplay_receiver_abi_version() { return 3; }
extern "C" uint64_t airplay_receiver_attach(uint64_t handle, int64_t port, void* post) {
    try { auto channel = airplay::receiver_channel(handle); return channel && port && post ? channel->attach(port, post) : 0; } catch (...) { return 0; }
}
extern "C" bool airplay_receiver_detach(uint64_t handle, uint64_t token) {
    try { auto channel = airplay::receiver_channel(handle); return channel && channel->detach(token); } catch (...) { return false; }
}
extern "C" bool airplay_receiver_control(uint64_t handle, uint64_t token, int64_t request, const char* json, size_t size) {
    try {
        auto channel = airplay::receiver_channel(handle);
        if (!channel) return false;
        // Invalid inputs still complete asynchronously for a live subscription.
        if (!json || size > 1024 * 1024 || memchr(json, '\0', size)) {
            return channel->submit(handle, token, request, []() -> airplay::Json { throw std::runtime_error("Invalid receiver JSON object"); });
        }
        std::string bytes(json, size);
        return channel->submit(handle, token, request, [handle, bytes = std::move(bytes)] {
            return airplay::control_receiver(handle, bytes);
        });
    } catch (...) { return false; }
}
