// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../../playback/video_scheduler.h"
#include "../../playback/timeline.h"
#include <memory>
#include <stdexcept>
#include <vector>

namespace airplay_test {
inline void video_scheduler_test() {
    auto check = [](bool ok, const char *message) { if (!ok) throw std::runtime_error(message); };
    // Exercise the default drain clock with deadlines from the receive core.
    // Injected test clocks cannot expose differing epochs after macOS sleep.
    airplay::VideoScheduler live;
    live.begin(1);
    bool released = false, visible = false;
    live.enqueue(airplay::monotonic_ns(), 1, [&](bool show) { released = true; visible = show; });
    live.drain();
    check(released && visible, "current decoded frame reaches display using the receive clock");
    released = false;
    live.enqueue(airplay::monotonic_ns() + airplay::kSecond, 1, [&](bool) { released = true; });
    live.drain();
    check(!released, "default drain clock holds future frames");
    live.clear();
    live.begin(2);
    visible = true; released = false;
    live.enqueue(airplay::monotonic_ns() - airplay::kSecond, 2, [&](bool show) { released = true; visible = show; });
    live.drain();
    check(released && !visible, "default drain clock still discards expired frames");

    constexpr int64_t now = 1000000000;
    // A short stall is inside the late tolerance, but replaying every missed
    // picture still floods the display. Keep the latest due picture instead.
    {
        airplay::VideoScheduler recovery(0, 16);
        recovery.begin(1);
        std::vector<int> visible, skipped;
        for (int i : {3, 0, 6, 1, 5, 2, 4}) {
            recovery.enqueue(now - 100000000 + i * 16000000, 1,
                [&, i](bool show) { (show ? visible : skipped).push_back(i); });
        }
        recovery.enqueue(now + 16000000, 1, [&](bool show) { if (show) visible.push_back(7); });
        recovery.drain(now);
        check(visible == std::vector<int>{6} && skipped.size() == 6,
              "100 ms recovery coalesces missed pictures into the latest due frame");
        check(recovery.stats().pending == 1, "recovery retains future pictures");
        recovery.diagnostics(now);
        const auto recovery_report = recovery.diagnostics(now + 5000000000LL);
        check(recovery_report.find("coalesced_drop=6") != std::string::npos && recovery.stats().dropped == 6,
              "recovery drops are visible in diagnostics and cumulative counters");
        recovery.drain(now + 16000000);
        check(visible == std::vector<int>({6, 7}), "future picture still presents at its deadline");
    }
    {
        airplay::VideoScheduler timed(50000000, 16);
        timed.begin(1);
        int submitted = 0, dropped = 0;
        for (auto due : {now - 10000000, now + 10000000, now + 30000000}) {
            timed.enqueue(due, 1, [&](bool show) { show ? ++submitted : ++dropped; });
        }
        timed.drain(now);
        check(submitted == 3 && dropped == 0, "early host handoff does not coalesce future pictures");
    }
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
    scheduler.drain(now + 20000000);
    scheduler.drain(now + 30000000);
    check(shown == std::vector<int>({1, 2, 3}), "B-frame timestamps present monotonically");
    scheduler.enqueue(now + 20000000, 7, lease(4));
    scheduler.enqueue(now - 200000000, 7, lease(5));
    scheduler.drain(now + 30000000);
    check(discarded.size() == 2 && shown.size() == 3, "late or already passed pictures are discarded");

    const auto stats = scheduler.stats();
    check(stats.submitted == 3 && stats.dropped == 2 && stats.pending == 0,
          "telemetry distinguishes scheduler releases, drops and pending pictures");
    scheduler.diagnostics(now);
    scheduler.diagnostics(now + 6000000000LL);
    check(scheduler.stats().submitted == 3 && scheduler.stats().dropped == 2,
          "periodic diagnostic logging does not consume overlay counters");

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
    check(scheduler.stats().submitted == 4 && scheduler.stats().dropped == 6 && scheduler.stats().pending == 0,
          "overflow counts as a drop, lifecycle cancellations do not");
    check(shown.size() + discarded.size() == 27, "no leaked or duplicate lease completion");

    airplay::VideoScheduler flutter(2000000);
    flutter.begin(1);
    flutter.enqueue(now + 10000000, 1, lease(8));
    check(flutter.next_deadline() == now + 8000000, "Flutter acquisition lead keeps original PTS");
    flutter.drain(now + 7999999);
    check(shown.back() == 7, "acquisition lead remains bounded");
    flutter.drain(now + 8000000);
    check(shown.back() == 8, "Flutter texture is submitted with acquisition lead");

    airplay::DeadlineSamples slack;
    slack.add(50000000); slack.add(-10000000);
    check(slack.min_ns == -10000000 && slack.max_ns == 50000000 && slack.total_ns / int64_t(slack.count) == 20000000,
          "deadline samples preserve both positive headroom and negative lateness");
    flutter.diagnostics(now);
    const auto report = flutter.diagnostics(now + 6000000000LL);
    check(report.find("release_slack_min_ms=2.000") != std::string::npos,
          "early submission is reported as positive deadline headroom");

    airplay::RenderTimingSamples rendered;
    rendered.add(now, now + 1000000, now + 100000000);
    rendered.add(now + 16000000, now + 17000000, now + 100000000);
    check(rendered.gap.count == 1 && rendered.gap.max_ns == 16000000,
          "batched render callbacks use carried timestamps for frame pacing");
    check(rendered.callback_delay.max_ns == 99000000 && rendered.slack.min_ns == -1000000,
          "callback delivery delay is separate from actual display lateness");
    rendered.add(now, now + 1000000, now + 101000000);
    check(rendered.nonpositive_steps == 1 && rendered.last_render_ns == now + 17000000,
          "out-of-order notifications do not move the render watermark backwards");
}
} // namespace airplay_test
