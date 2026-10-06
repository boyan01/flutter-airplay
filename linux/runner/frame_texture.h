// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <flutter_linux/flutter_linux.h>
#include <cstdint>
#include <string>

#include "../../native/include/airplay/linux_video.h"

// Register/Notify/destruction belong to GTK's main thread. Receive and Clear may
// be called by a worker; they replace pending pixels or a retained native frame.
// frame_pump keeps GPU-only redraws on the Flutter frame cadence and buffers one
// input frame (up to three queued leases). It stops and drains on input stalls.
class FrameTexture {
 public:
  explicit FrameTexture(FlTextureRegistrar* registrar, bool gpu = false, bool frame_pump = false);
  ~FrameTexture();
  FrameTexture(const FrameTexture&) = delete;
  FrameTexture& operator=(const FrameTexture&) = delete;

  bool Register();
  int64_t identifier() const;
  bool Receive(const AirplayLinuxVideoFrame& frame);
  void Clear();
  void Notify();
  void NotificationRequested(bool coalesced = false);
  std::string Diagnostics();
  std::string TakeError();

 private:
  FlTextureRegistrar* registrar_;
  FlTexture* texture_;
  bool gpu_;
  bool registered_ = false;
};
