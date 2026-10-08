// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <CoreVideo/CoreVideo.h>
#include <array>
#include <algorithm>
#include <cmath>

// Read a fixture pixel without assuming the decoder's output layout. Color
// assertions exercise both the native NV12 path and the iPad BGRA path.
inline std::array<int, 3> apple_rgb(CVPixelBufferRef image) {
    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    std::array<int, 3> rgb{};
    const auto format = CVPixelBufferGetPixelFormatType(image);
    if (format == kCVPixelFormatType_32BGRA) {
        const auto *p = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(image));
        rgb = {p[2], p[1], p[0]};
    } else {
        const auto *y = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(image, 0));
        const auto *uv = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(image, 1));
        const double luma = (y[0] - 16) * 255.0 / 219.0;
        const double u = (uv[0] - 128) * 255.0 / 224.0, v = (uv[1] - 128) * 255.0 / 224.0;
        auto matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nullptr);
        const bool bt709 = matrix && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
        if (matrix) CFRelease(matrix);
        auto channel = [](double x) { return std::clamp(int(std::lround(x)), 0, 255); };
        rgb = {channel(luma + (bt709 ? 1.5748 : 1.402) * v),
               channel(luma - (bt709 ? 0.1873 : 0.3441) * u - (bt709 ? 0.4681 : 0.7141) * v),
               channel(luma + (bt709 ? 1.8556 : 1.772) * u)};
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    return rgb;
}
