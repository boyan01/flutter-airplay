// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>
#include <cstring>
#if defined(__SSE2__) || defined(_M_X64)
#include <emmintrin.h>
#endif

namespace airplay {
inline bool windows_yuv420_to_rgba_scalar(const uint8_t *bytes, size_t length, size_t width,
                                  size_t height, size_t stride, bool bt709, bool full_range,
                                  std::vector<uint8_t> &rgba, bool p010) {
    const size_t sample_bytes = p010 ? 2 : 1;
    if (!bytes || !width || !height || width > 4096 || height > 4096 ||
        (width & 1) || (height & 1) || stride < width * sample_bytes || stride > 32768 ||
        length < stride * (height + height / 2)) return false;
    rgba.resize(width * height * 4);
    auto clip = [](int n) { return uint8_t(std::clamp(n, 0, 255)); };
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width; ++x) {
            // P010 stores ten-bit samples in the high bits of little-endian words.
            // The Flutter RGBA texture is eight-bit; keep the high eight bits.
            const size_t high = p010 ? 1 : 0;
            int luma = bytes[y * stride + x * sample_bytes + high];
            const auto chroma = stride * height + (y / 2) * stride + (x & ~size_t(1)) * sample_bytes;
            int u = int(bytes[chroma + high]) - 128;
            int v = int(bytes[chroma + sample_bytes + high]) - 128;
            int c = full_range ? luma * 256 : std::max(0, luma - 16) * 298;
            const int rv = full_range ? (bt709 ? 403 : 359) : (bt709 ? 459 : 409);
            const int gu = full_range ? (bt709 ? 48 : 88) : (bt709 ? 55 : 100);
            const int gv = full_range ? (bt709 ? 120 : 183) : (bt709 ? 136 : 208);
            const int bu = full_range ? (bt709 ? 475 : 454) : (bt709 ? 541 : 516);
            auto *out = rgba.data() + (y * width + x) * 4;
            out[0] = clip((c + rv * v + 128) >> 8);
            out[1] = clip((c - gu * u - gv * v + 128) >> 8);
            out[2] = clip((c + bu * u + 128) >> 8);
            out[3] = 255;
        }
    }
    return true;
}
// SSE2 is part of the Windows x64 baseline. Convert four pixels together;
// retain the scalar path for other architectures and widths not divisible by four.
inline bool windows_yuv420_to_rgba(const uint8_t *bytes, size_t length, size_t width,
                                  size_t height, size_t stride, bool bt709, bool full_range,
                                  std::vector<uint8_t> &rgba, bool p010) {
#if defined(__SSE2__) || defined(_M_X64)
    const size_t sample_bytes = p010 ? 2 : 1;
    if (!bytes || !width || !height || width > 4096 || height > 4096 ||
        (width & 1) || (height & 1) || stride < width * sample_bytes || stride > 32768 ||
        length < stride * (height + height / 2)) return false;
    if (width % 4) return windows_yuv420_to_rgba_scalar(bytes, length, width, height, stride,
                                                       bt709, full_range, rgba, p010);
    rgba.resize(width * height * 4);
    const auto zero = _mm_setzero_si128();
    const auto rounding = _mm_set1_epi32(128);
    const auto chroma_bias = _mm_set1_epi16(128);
    const auto alpha = _mm_set1_epi8(char(255));
    const int rv = full_range ? (bt709 ? 403 : 359) : (bt709 ? 459 : 409);
    const int gu = full_range ? (bt709 ? 48 : 88) : (bt709 ? 55 : 100);
    const int gv = full_range ? (bt709 ? 120 : 183) : (bt709 ? 136 : 208);
    const int bu = full_range ? (bt709 ? 475 : 454) : (bt709 ? 541 : 516);
    auto multiply = [&](const __m128i values, int coefficient) {
        return _mm_madd_epi16(_mm_unpacklo_epi16(values, zero), _mm_set1_epi32(coefficient));
    };
    auto clip = [&](const __m128i values) {
        const auto words = _mm_packs_epi32(_mm_srai_epi32(_mm_add_epi32(values, rounding), 8), zero);
        return _mm_packus_epi16(words, zero);
    };
    for (size_t y = 0; y < height; ++y) {
        const auto *luma = bytes + y * stride;
        const auto *chroma = bytes + stride * height + (y / 2) * stride;
        auto *output = rgba.data() + y * width * 4;
        for (size_t x = 0; x < width; x += 4) {
            __m128i yy, uv;
            if (p010) {
                yy = _mm_srli_epi16(_mm_loadl_epi64(reinterpret_cast<const __m128i *>(luma + x * 2)), 8);
                uv = _mm_srli_epi16(_mm_loadl_epi64(reinterpret_cast<const __m128i *>(chroma + x * 2)), 8);
            } else {
                uint32_t y_bytes, uv_bytes;
                std::memcpy(&y_bytes, luma + x, 4); std::memcpy(&uv_bytes, chroma + x, 4);
                yy = _mm_unpacklo_epi8(_mm_cvtsi32_si128(y_bytes), zero);
                uv = _mm_unpacklo_epi8(_mm_cvtsi32_si128(uv_bytes), zero);
            }
            const auto u = _mm_sub_epi16(_mm_shufflelo_epi16(uv, _MM_SHUFFLE(2, 2, 0, 0)), chroma_bias);
            const auto v = _mm_sub_epi16(_mm_shufflelo_epi16(uv, _MM_SHUFFLE(3, 3, 1, 1)), chroma_bias);
            if (!full_range) yy = _mm_subs_epu16(yy, _mm_set1_epi16(16));
            const auto c = multiply(yy, full_range ? 256 : 298);
            const auto r = clip(_mm_add_epi32(c, multiply(v, rv)));
            const auto g = clip(_mm_sub_epi32(_mm_sub_epi32(c, multiply(u, gu)), multiply(v, gv)));
            const auto b = clip(_mm_add_epi32(c, multiply(u, bu)));
            const auto rg = _mm_unpacklo_epi8(r, g);
            const auto ba = _mm_unpacklo_epi8(b, alpha);
            _mm_storeu_si128(reinterpret_cast<__m128i *>(output + x * 4), _mm_unpacklo_epi16(rg, ba));
        }
    }
    return true;
#else
    return windows_yuv420_to_rgba_scalar(bytes, length, width, height, stride,
                                         bt709, full_range, rgba, p010);
#endif
}
inline bool windows_nv12_to_rgba(const uint8_t *bytes, size_t length, size_t width,
    size_t height, size_t stride, bool bt709, bool full_range, std::vector<uint8_t> &rgba) {
    return windows_yuv420_to_rgba(bytes, length, width, height, stride, bt709, full_range, rgba, false);
}
inline bool windows_p010_to_rgba(const uint8_t *bytes, size_t length, size_t width,
    size_t height, size_t stride, bool bt709, bool full_range, std::vector<uint8_t> &rgba) {
    return windows_yuv420_to_rgba(bytes, length, width, height, stride, bt709, full_range, rgba, true);
}
} // namespace airplay
