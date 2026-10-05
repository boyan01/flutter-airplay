// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <string>

namespace airplay {
inline constexpr std::array<const char*, 5> video_qualities{"auto", "720", "1080", "1440", "2160"};
inline bool valid_video_quality(const std::string& quality) {
    return std::find(video_qualities.begin(), video_qualities.end(), quality) != video_qualities.end();
}
inline int requested_video_height(const std::string& quality, int screen_height) {
    return quality == "auto" ? std::clamp(screen_height, 480, 2160) / 2 * 2 : std::stoi(quality);
}
inline int requested_video_width(int height) { return (height * 16 / 9 + 1) / 2 * 2; }
}  // namespace airplay
