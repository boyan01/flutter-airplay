# Apple ALAC decoder provenance

Source: https://github.com/macosforge/alac
Base commit: c38887c5c5e64a4b31108733bd79ca9b2496d987
License: Apache-2.0; see [LICENSE](LICENSE).

The decoder, bit utilities, entropy decoder, predictor, channel matrix and
portable endian utilities are copied from `codec/`. Encoder and conversion
utility sources are excluded. Android links this code; macOS uses AudioConverter.

Local changes:

- Add a decoder-only CMake target with explicit little-endian configuration for
  the supported arm64 platforms, wrapping integer arithmetic and aliasing flags.
- Bound bit reads and advances and propagate truncation errors.
- Validate cookie length, allocation size, channel count and bit depth.
- Bound partial-frame sample counts, predictor warm-up and channel mixing shifts.
- Limit entropy decoding to the remaining packet bytes and validate zero runs.
- Handle zero predictor denominator shifts without a negative shift count.
- Normalize trailing whitespace and mixed indentation without changing code.

The caller pads compressed input by eight bytes for bounded entropy lookahead
while preserving the actual input length. Original source notices are retained.
