// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreVideo
func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
final class TestVideoOutput: ReceiverVideoOutput {
    var textureIdentifier: Int64 = 0
    var begins = 0, ends = 0
    func begin() throws { begins += 1 }
    func receive(_ frame: CVPixelBuffer) {}
    func clear() {}
    func end() { ends += 1 }
}
let suite = "receiver-tests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let host = ReceiverHost(defaults: defaults)
let video = TestVideoOutput(); host.videoOutput = video
try host.queue.sync {
    require(host.snapshot()["autoStart"] as? Bool == true, "auto receive defaults on")
    try host.save(name: "Synthetic Receiver", path: "", autoStart: false)
    require(host.snapshot()["autoStart"] as? Bool == false, "auto receive preference persists")
    let capabilities = host.snapshot()["capabilities"] as! [String: Any]
    require(capabilities["supportsExecutablePath"] as? Bool == false, "embedded library does not require executable path")
    require(host.snapshot()["textureId"] as? Int64 == 0, "texture ID zero remains valid")
    for name in ["", String(repeating: "a", count: 51), "bad\nname"] {
        do { try host.save(name: name, path: ""); require(false, "invalid name accepted") } catch {}
    }
    do { try host.save(name: "Synthetic Receiver", path: "/external/receiver"); require(false, "external executable accepted") } catch {}
    try host.check(path: "")
    require((host.snapshot()["logs"] as! [[String: Any]]).count == 1, "embedded library check produces diagnostics")
    host.stop(); host.stop()
    require(host.snapshot()["status"] as? String == "stopped", "stopping an idle host is idempotent")
}
host.shutdown()
