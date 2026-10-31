// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter_plugin_registrar.h>
#include <memory>
#include <functional>
#include <flutter/encodable_value.h>

class ReceiverBridge {
public:
    static constexpr UINT kDispatchMessage = WM_APP + 73;
    // registrar's engine hosts the video texture; construct and destroy on the platform thread.
    ReceiverBridge(HWND window, flutter::BinaryMessenger *messenger, FlutterDesktopPluginRegistrarRef registrar,
                   std::function<void(const flutter::EncodableMap &)> on_snapshot);
    ~ReceiverBridge();
    void Dispatch();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
