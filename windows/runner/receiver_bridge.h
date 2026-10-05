// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/texture_registrar.h>
#include <memory>
#include <functional>
#include <flutter/encodable_value.h>
struct IDXGIAdapter;

class ReceiverBridge {
public:
    static constexpr UINT kDispatchMessage = WM_APP + 73;
    ReceiverBridge(HWND window, flutter::BinaryMessenger *messenger, flutter::TextureRegistrar *textures,
                   std::function<void(const flutter::EncodableMap &)> on_snapshot, IDXGIAdapter *adapter = nullptr);
    ~ReceiverBridge();
    void Dispatch();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
