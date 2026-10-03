// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

// Owns an Avahi poll thread. Successful Start means both services have completed
// registration, not merely that the local listener has opened.
class Discovery {
 public:
  Discovery();
  ~Discovery();
  Discovery(const Discovery&) = delete;
  Discovery& operator=(const Discovery&) = delete;

  bool Start(const std::string& name, const std::array<uint8_t, 6>& identity,
             uint16_t port, std::vector<uint8_t> airplay_txt,
             std::vector<uint8_t> raop_txt,
             std::function<void(const std::string&)> failure,
             std::string* error);
  void Stop();
  static bool Check(std::string* error);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
