// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreVideo
import CoreGraphics
func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
final class TestVideoOutput: ReceiverVideoOutput {
    var textureIdentifier: Int64 = 0
    var begins = 0, ends = 0
    func begin() throws { begins += 1 }
    func receive(_ frame: CVPixelBuffer, deadline: Int64) {}
    func clear() {}
    func end() { ends += 1 }
}
let suite = "receiver-tests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let support = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
defer { try? FileManager.default.removeItem(at: support) }
let host = ReceiverHost(defaults: defaults, supportDirectory: support)
let video = TestVideoOutput(); host.videoOutput = video
try host.queue.sync {
    let displayMode = CGDisplayCopyDisplayMode(CGMainDisplayID())!
    require(host.snapshot()["screenWidth"] as? Int == displayMode.pixelWidth &&
            host.snapshot()["screenHeight"] as? Int == displayMode.pixelHeight,
            "screen size uses display-mode pixels on Retina")
    let defaultName = host.snapshot()["defaultName"] as? String
    require(defaultName == host.snapshot()["name"] as? String, "default name matches initial system name")
    require(try !host.applySettings(), "applying settings does not start a stopped receiver")
    require(host.snapshot()["autoStart"] as? Bool == true, "auto receive defaults on")
    try host.save(name: "Synthetic Receiver", path: "", autoStart: false)
    require(host.snapshot()["autoStart"] as? Bool == false, "auto receive runtime preference updates")
    require(host.snapshot()["videoQualities"] as? [String] == ["auto", "720", "1080", "1440", "2160"], "macOS exposes all quality presets")
    for (quality, width, height) in [("720", 1280, 720), ("1080", 1920, 1080), ("1440", 2560, 1440), ("2160", 3840, 2160)] {
        try host.save(name: "Synthetic Receiver", path: "", videoQuality: quality)
        require(defaults.string(forKey: "videoQuality") == nil, "native settings do not write platform defaults: \(quality)")
        let size = host.requestedVideoSize()
        require(size.width == width && size.height == height, "receiver requests selected size: \(quality)")
    }
    do { try host.save(name: "Synthetic Receiver", path: "", videoQuality: "invalid"); require(false, "invalid quality accepted") } catch {}
    try host.save(name: "Synthetic Receiver", path: "", videoQuality: "auto")
    let size = host.requestedVideoSize()
    require(size.height == min(2160, max(480, displayMode.pixelHeight)) / 2 * 2,
            "auto quality uses display-mode pixels with a bounded even size")
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    require(CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount) == .success,
            "active displays can be enumerated")
    for display in displays.prefix(Int(displayCount)) {
        host.displayID = display
        let mode = CGDisplayCopyDisplayMode(display)!
        let snapshot = host.snapshot()
        require(snapshot["screenWidth"] as? Int == mode.pixelWidth &&
                snapshot["screenHeight"] as? Int == mode.pixelHeight,
                "screen size follows the selected playback display")
        require(host.requestedVideoSize().height == min(2160, max(480, mode.pixelHeight)) / 2 * 2,
                "auto quality follows the selected playback display")
    }
    host.displayID = UInt32.max
    require(host.snapshot()["screenHeight"] as? Int == displayMode.pixelHeight,
            "a disconnected playback display falls back to the main display")
    host.displayID = CGMainDisplayID()
    require(host.snapshot()["textureId"] as? Int64 == 0, "texture ID zero remains valid")
    for name in ["", String(repeating: "a", count: 51), "bad\nname"] {
        do { try host.save(name: name, path: ""); require(false, "invalid name accepted") } catch {}
    }
    do { try host.save(name: "Synthetic Receiver", path: "/external/receiver"); require(false, "external executable accepted") } catch {}
    try host.check(path: "")
    require(host.snapshot()["defaultName"] as? String == defaultName, "saving a custom name preserves the reset target")
    try host.start(name: "Synthetic Receiver", path: "")
    try host.save(name: "Renamed Receiver", path: "", videoQuality: "720")
    require(host.snapshot()["receivingName"] as? String == "Synthetic Receiver", "saved settings do not pretend to be advertised")
    require(try host.applySettings(), "idle receiver applies saved settings")
    require(host.snapshot()["receivingName"] as? String == "Renamed Receiver", "idle restart updates advertised name")
    require((host.snapshot()["activeSettings"] as? [String: Any])?["videoQuality"] as? String == "720", "idle restart applies quality with the name")
    host.stop(); host.stop()
    require(host.snapshot()["status"] as? String == "stopped", "stopping an idle host is idempotent")
    try host.start(name: "Synthetic Receiver", path: "")
    host.reportOutputError("Synthetic native display failure")
    require(host.snapshot()["status"] as? String == "error" &&
            host.snapshot()["message"] as? String == "Synthetic native display failure",
            "asynchronous display failure stops playback and reaches shared receiver state")
    host.stop()
}
host.shutdown()
