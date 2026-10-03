// SPDX-License-Identifier: GPL-3.0-only
#include "discovery.h"

#include <avahi-client/client.h>
#include <avahi-client/publish.h>
#include <avahi-common/error.h>
#include <avahi-common/simple-watch.h>
#include <avahi-common/strlst.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>
#include <utility>

namespace {
std::string AvahiError(int code) {
  return std::string("Avahi discovery: ") + avahi_strerror(code) +
         ". Ensure avahi-daemon and the system D-Bus service are running.";
}
}  // namespace

struct Discovery::Impl {
  AvahiSimplePoll* poll = nullptr;
  AvahiClient* client = nullptr;
  AvahiEntryGroup* group = nullptr;
  std::thread worker;
  std::atomic<bool> stopping{false};
  std::mutex mutex;
  std::condition_variable changed;
  bool established = false;
  std::string error;
  std::string name;
  std::string raop_name;
  uint16_t port = 0;
  std::vector<uint8_t> airplay_txt;
  std::vector<uint8_t> raop_txt;
  std::function<void(const std::string&)> failure;

  void Fail(const std::string& detail) {
    bool notify = false;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (error.empty()) {
        error = detail;
        notify = established;
      }
    }
    changed.notify_all();
    if (notify && !stopping && failure) failure(detail);
    stopping = true;
  }

  static void GroupChanged(AvahiEntryGroup* current, AvahiEntryGroupState state,
                           void* data) {
    auto* self = static_cast<Impl*>(data);
    if (state == AVAHI_ENTRY_GROUP_ESTABLISHED) {
      {
        std::lock_guard<std::mutex> lock(self->mutex);
        self->established = true;
      }
      self->changed.notify_all();
    } else if (state == AVAHI_ENTRY_GROUP_COLLISION) {
      self->Fail("Avahi discovery: this receiver name is already in use. "
                 "Choose another device name and start again.");
    } else if (state == AVAHI_ENTRY_GROUP_FAILURE) {
      self->Fail(AvahiError(avahi_client_errno(
          avahi_entry_group_get_client(current))));
    }
  }

  void Publish(AvahiClient* current) {
    if (group || stopping) return;
    group = avahi_entry_group_new(current, GroupChanged, this);
    if (!group) {
      Fail(AvahiError(avahi_client_errno(current)));
      return;
    }
    AvahiStringList* video = nullptr;
    AvahiStringList* audio = nullptr;
    if (airplay_txt.empty() || raop_txt.empty() ||
        avahi_string_list_parse(airplay_txt.data(), airplay_txt.size(), &video) < 0 ||
        avahi_string_list_parse(raop_txt.data(), raop_txt.size(), &audio) < 0) {
      avahi_string_list_free(video);
      avahi_string_list_free(audio);
      Fail("Avahi discovery: invalid AirPlay TXT records.");
      return;
    }
    int result = avahi_entry_group_add_service_strlst(
        group, AVAHI_IF_UNSPEC, AVAHI_PROTO_UNSPEC,
        static_cast<AvahiPublishFlags>(0), name.c_str(), "_airplay._tcp",
        nullptr, nullptr, port, video);
    if (result >= 0) {
      result = avahi_entry_group_add_service_strlst(
          group, AVAHI_IF_UNSPEC, AVAHI_PROTO_UNSPEC,
          static_cast<AvahiPublishFlags>(0), raop_name.c_str(), "_raop._tcp",
          nullptr, nullptr, port, audio);
    }
    avahi_string_list_free(video);
    avahi_string_list_free(audio);
    if (result >= 0) result = avahi_entry_group_commit(group);
    if (result < 0) Fail(AvahiError(result));
  }

  static void ClientChanged(AvahiClient* current, AvahiClientState state,
                            void* data) {
    auto* self = static_cast<Impl*>(data);
    if (state == AVAHI_CLIENT_S_RUNNING) {
      self->Publish(current);
    } else if (state == AVAHI_CLIENT_FAILURE) {
      self->Fail(AvahiError(avahi_client_errno(current)));
    } else if (state == AVAHI_CLIENT_S_COLLISION ||
               state == AVAHI_CLIENT_S_REGISTERING) {
      // Losing publication after startup must never leave a false waiting state.
      bool was_established;
      {
        std::lock_guard<std::mutex> lock(self->mutex);
        was_established = self->established;
      }
      if (was_established) {
        self->Fail("Avahi discovery changed while receiving. Start the receiver again.");
      } else if (self->group) {
        avahi_entry_group_free(self->group);
        self->group = nullptr;
      }
    }
  }

  void Run() {
    poll = avahi_simple_poll_new();
    if (!poll) {
      Fail("Cannot initialize the Avahi discovery event loop.");
      return;
    }
    int code = 0;
    // Deliberately omit NO_FAIL: a missing daemon is an actionable failure.
    client = avahi_client_new(avahi_simple_poll_get(poll),
                              static_cast<AvahiClientFlags>(0), ClientChanged,
                              this, &code);
    if (!client) Fail(AvahiError(code));
    while (client && !stopping) {
      if (avahi_simple_poll_iterate(poll, 100) < 0) {
        Fail("The Avahi discovery event loop failed.");
      }
    }
    if (client) avahi_client_free(client);  // Also withdraws both services.
    client = nullptr;
    group = nullptr;
    avahi_simple_poll_free(poll);
    poll = nullptr;
  }
};

Discovery::Discovery() = default;
Discovery::~Discovery() { Stop(); }

bool Discovery::Start(const std::string& name,
                      const std::array<uint8_t, 6>& identity, uint16_t port,
                      std::vector<uint8_t> airplay_txt,
                      std::vector<uint8_t> raop_txt,
                      std::function<void(const std::string&)> failure,
                      std::string* error) {
  Stop();
  impl_ = std::make_unique<Impl>();
  auto* self = impl_.get();
  self->name = name;
  char prefix[14];
  std::snprintf(prefix, sizeof(prefix), "%02X%02X%02X%02X%02X%02X@",
                identity[0], identity[1], identity[2], identity[3], identity[4],
                identity[5]);
  self->raop_name = prefix + name;
  self->port = port;
  self->airplay_txt = std::move(airplay_txt);
  self->raop_txt = std::move(raop_txt);
  self->failure = std::move(failure);
  self->worker = std::thread([self] { self->Run(); });
  std::unique_lock<std::mutex> lock(self->mutex);
  const bool completed = self->changed.wait_for(lock, std::chrono::seconds(6),
      [self] { return self->established || !self->error.empty(); });
  if (!completed) self->error = "Avahi discovery registration timed out. "
                                "Check avahi-daemon and the local network.";
  const bool success = self->established && self->error.empty();
  if (!success && error) *error = self->error;
  lock.unlock();
  if (!success) Stop();
  return success;
}

void Discovery::Stop() {
  if (!impl_) return;
  impl_->stopping = true;
  if (impl_->worker.joinable()) impl_->worker.join();
  impl_.reset();
}

bool Discovery::Check(std::string* error) {
  auto* poll = avahi_simple_poll_new();
  if (!poll) {
    if (error) *error = "Cannot initialize the Avahi discovery event loop.";
    return false;
  }
  int code = 0;
  auto* client = avahi_client_new(avahi_simple_poll_get(poll),
                                 static_cast<AvahiClientFlags>(0), nullptr,
                                 nullptr, &code);
  const bool available = client != nullptr;
  if (!available && error) *error = AvahiError(code);
  if (client) avahi_client_free(client);
  avahi_simple_poll_free(poll);
  return available;
}
