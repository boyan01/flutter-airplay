// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <flutter_linux/flutter_linux.h>
#include <cstdint>
#include <string>

#include "../../native/backends/linux/linux_video.h"

// Register/Notify/destruction belong to GTK's main thread. Receive and Clear may
// be called by a worker; they only replace the pending, owned RGBA pixels.
class FrameTexture {
 public:
  explicit FrameTexture(FlTextureRegistrar* registrar);
  ~FrameTexture();
  FrameTexture(const FrameTexture&) = delete;
  FrameTexture& operator=(const FrameTexture&) = delete;

  bool Register();
  int64_t identifier() const;
  bool Receive(const AirplayLinuxVideoFrame& frame);
  void Clear();
  void Notify();
  void NotificationRequested();
  std::string Diagnostics();

 private:
  FlTextureRegistrar* registrar_;
  FlPixelBufferTexture* texture_;
  bool registered_ = false;
};
