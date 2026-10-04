// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <flutter_linux/flutter_linux.h>
#include <memory>
#include <functional>

// Create and destroy on the GTK main thread, while the Flutter engine is alive.
// Destruction synchronously joins the receiver, playback and discovery workers.
class ReceiverHost {
 public:
  ReceiverHost(FlBinaryMessenger* messenger, FlTextureRegistrar* registrar,
               std::function<void(FlValue*)> on_snapshot = {});
  ~ReceiverHost();
  ReceiverHost(const ReceiverHost&) = delete;
  ReceiverHost& operator=(const ReceiverHost&) = delete;

 private:
  struct State;
  std::shared_ptr<State> state_;
};
