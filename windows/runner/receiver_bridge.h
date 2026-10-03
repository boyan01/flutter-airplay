// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/texture_registrar.h>
#include <memory>

class ReceiverBridge {
public:
    static constexpr UINT kDispatchMessage = WM_APP + 73;
    ReceiverBridge(HWND window, flutter::BinaryMessenger *messenger, flutter::TextureRegistrar *textures);
    ~ReceiverBridge();
    void Dispatch();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
