// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
#define AIRPLAY_LINUX_DEFAULT(value) = value
#else
#define AIRPLAY_LINUX_DEFAULT(value)
#endif

// Borrowed RGBA pixels, or a native decoded-frame lease. The native object is
// opaque to hosts; retain/release keep its decoder/device alive across threads.
// Never retain the descriptor itself beyond the synchronous frame callback.
typedef struct AirplayLinuxVideoFrame {
    const uint8_t *data;
    int stride;
    int width;
    int height;
    void *native_frame AIRPLAY_LINUX_DEFAULT(nullptr);
    void *(*retain)(void *) AIRPLAY_LINUX_DEFAULT(nullptr);
    void (*release)(void *) AIRPLAY_LINUX_DEFAULT(nullptr);
} AirplayLinuxVideoFrame;

struct AirplayLinuxVideoOptions {
    bool hardware AIRPLAY_LINUX_DEFAULT(true);
    bool gpu_output AIRPLAY_LINUX_DEFAULT(true);
};

#undef AIRPLAY_LINUX_DEFAULT

#ifdef __cplusplus
#include <memory>
#include <string>
namespace airplay {
// All operations, including destruction, require the same current GL context.
// Hosts own the context; the backend owns color conversion and CUDA interop.
class LinuxGpuRenderer {
public:
    explicit LinuxGpuRenderer(bool cuda_interop = true);
    ~LinuxGpuRenderer();
    bool render(const AirplayLinuxVideoFrame &, uint32_t &texture, std::string &error);
    const char *path() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
#endif
