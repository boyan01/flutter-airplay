// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <stdint.h>

// Borrowed RGBA pixels, top row first. Copy them before the synchronous frame
// callback returns; never retain the descriptor.
typedef struct AirplayLinuxVideoFrame {
    const uint8_t *data;
    int stride;
    int width;
    int height;
} AirplayLinuxVideoFrame;
