// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <stdint.h>

// Linux AirplayCallbacks.frame receives a pointer to this borrowed frame.
// Pixels are RGBA8, top row first, with a positive byte stride. Both the
// structure and its pixels are valid only until the synchronous callback
// returns. A host that publishes the frame on another thread must copy it.
// Dimensions come from the decoded stream, including changes in orientation.
typedef struct AirplayLinuxVideoFrame {
    const uint8_t *data;
    int stride;
    int width;
    int height;
} AirplayLinuxVideoFrame;
