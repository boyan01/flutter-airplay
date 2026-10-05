// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "video_scheduler.h"
#include <memory>
#include <stdexcept>
#include <vector>

namespace airplay_test {
inline void video_scheduler_test() {
    auto check = [](bool ok, const char *message) { if (!ok) throw std::runtime_error(message); };
    constexpr int64_t now = 1000000000;
    std::vector<int> shown, discarded;
    airplay::VideoScheduler scheduler(0);
    scheduler.begin(7);
    auto lease = [&](int id) {
        return [&, id](bool show) { (show ? shown : discarded).push_back(id); };
    };
    scheduler.enqueue(now + 30000000, 7, lease(3));
    scheduler.enqueue(now + 10000000, 7, lease(1));
    scheduler.enqueue(now + 20000000, 7, lease(2));
    check(!scheduler.can_decode(), "completed pictures backpressure compressed input");
    check(scheduler.next_deadline() == now + 10000000, "decode-order output wakes for earliest PTS");
    scheduler.drain(now);
    check(shown.empty() && discarded.empty(), "future output does not block or submit early");
    scheduler.drain(now + 10000000);
    check(shown == std::vector<int>{1} && scheduler.can_decode(), "presentation frees decode capacity");
    scheduler.drain(now + 30000000);
    check(shown == std::vector<int>({1, 2, 3}), "B-frame timestamps present monotonically");
    scheduler.enqueue(now + 20000000, 7, lease(4));
    scheduler.enqueue(now - 200000000, 7, lease(5));
    scheduler.drain(now + 30000000);
    check(discarded.size() == 2 && shown.size() == 3, "late or already passed pictures are discarded");

    auto pixels = std::make_shared<int>(42);
    std::weak_ptr<int> alive = pixels;
    scheduler.enqueue(now + 40000000, 7, [pixels](bool) {});
    pixels.reset();
    check(!alive.expired(), "queued picture owns native resources");
    scheduler.begin(8);
    check(alive.expired() && !scheduler.next_deadline(), "generation switch returns all old native leases");
    scheduler.enqueue(now + 50000000, 7, lease(6));
    check(discarded.back() == 6, "delayed output from previous generation is cancelled");
    scheduler.enqueue(now, 8, lease(7));
    scheduler.drain(now);
    check(shown.back() == 7, "new generation resets presentation watermark");
    for (int i = 0; i < 20; ++i) scheduler.enqueue(now + 1000000 + i, 8, lease(100 + i));
    const auto before = discarded.size();
    scheduler.clear();
    check(discarded.size() == before + 16, "overflow and reset release every retained lease exactly once");
    check(shown.size() + discarded.size() == 27, "no leaked or duplicate lease completion");

    airplay::VideoScheduler flutter(2000000);
    flutter.begin(1);
    flutter.enqueue(now + 10000000, 1, lease(8));
    check(flutter.next_deadline() == now + 8000000, "Flutter acquisition lead keeps original PTS");
    flutter.drain(now + 7999999);
    check(shown.back() == 7, "acquisition lead remains bounded");
    flutter.drain(now + 8000000);
    check(shown.back() == 8, "Flutter texture is submitted with acquisition lead");
}
} // namespace airplay_test
