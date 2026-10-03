import Foundation
import Darwin

func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
func waitFor(_ host: ReceiverHost, _ expected: String, timeout: Double = 8) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if host.queue.sync(execute: { host.snapshot()["status"] as? String == expected }) { return }
        Thread.sleep(forTimeInterval: 0.03)
    }
    print(host.queue.sync { host.snapshot() })
    require(false, "timed out waiting for \(expected)")
}
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let defaults = UserDefaults(suiteName: "receiver-tests-\(UUID().uuidString)")!
let mock = temp.appendingPathComponent("mock receiver").path
try """
#!/bin/sh
for arg in "$@"; do if [ "$arg" = "-h" ]; then exit 0; fi; done
printf 'AIRPLAY_RECEIVER_EVENT ready\\n' >&2
trap 'exit 0' TERM
while true; do sleep 0.1; done
""".write(toFile: mock, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mock)
// Foundation-only host tests inject a bounded transport fixture, never a window.
final class TestVideoOutput: ReceiverVideoOutput {
    let textureIdentifier: Int64 = -1
    var begins = 0, clears = 0, ends = 0
    func begin() throws -> String { begins += 1; return temp.appendingPathComponent("frames.sock").path }
    func clear() { clears += 1 }
    func end() { ends += 1 }
}
let video = TestVideoOutput()
let host = ReceiverHost(bundledPath: mock, inspectorPath: "/usr/bin/true", defaults: defaults)
host.videoOutput = video
try host.queue.sync {
    do { _ = try host.check(path: "/missing/receiver"); require(false, "missing binary rejected") }
    catch { require(error.localizedDescription.contains("找不到"), "missing binary is actionable") }
    do { try host.save(name: "", path: ""); require(false, "invalid name rejected") }
    catch { require(true, "empty device name rejected") }
    try host.start(name: "Living Room; $(touch ignored)", path: "")
}
waitFor(host, "waiting")
let pid = host.queue.sync { host.snapshot()["pid"] as! Int32 }
try host.queue.sync {
    try host.start(name: "duplicate", path: "")
    require(host.snapshot()["pid"] as! Int32 == pid, "duplicate start owns one process")
    host.receiveLine("connection request from iPhone")
    require(host.snapshot()["status"] as! String == "waiting", "connection request does not imply media")
    host.receiveLine("AIRPLAY_RECEIVER_EVENT streaming")
    require(host.snapshot()["status"] as! String == "streaming", "media contract updates streaming")
    host.receiveLine("AIRPLAY_RECEIVER_EVENT waiting")
    require(video.begins == 1 && video.clears == 1, "Embedded transport begins once and invalidates disconnect")
    host.stop()
    host.stop()
}
waitFor(host, "stopped")
require(kill(pid, 0) == -1, "stop reaps the owned receiver")
try host.queue.sync { try host.start(name: "Again", path: "") }
waitFor(host, "waiting")
let nextPID = host.queue.sync { host.snapshot()["pid"] as! Int32 }
host.shutdown()
require(kill(nextPID, 0) == -1, "application shutdown reaps its child")
require(video.ends >= 2, "Stop/quit ends embedded output")
let noGST = ReceiverHost(bundledPath: mock, inspectorPath: "/missing/gst-inspect", defaults: defaults)
do { _ = try noGST.queue.sync { try noGST.check(path: "") }; require(false, "missing inspector rejected") }
catch { require(true, "missing GStreamer inspector rejected") }

// A child that ignores SIGTERM verifies the bounded hard-stop fallback.
let stubborn = temp.appendingPathComponent("stubborn").path
try """
#!/bin/sh
for arg in "$@"; do if [ "$arg" = "-h" ]; then exit 0; fi; done
trap '' TERM
printf 'AIRPLAY_RECEIVER_EVENT ready\\n' >&2
while true; do sleep 0.1; done
""".write(toFile: stubborn, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubborn)
let stubbornHost = ReceiverHost(bundledPath: stubborn, inspectorPath: "/usr/bin/true", defaults: defaults)
stubbornHost.videoOutput = TestVideoOutput()
try stubbornHost.queue.sync { try stubbornHost.start(name: "Stubborn", path: "") }
waitFor(stubbornHost, "waiting")
stubbornHost.queue.sync { stubbornHost.stop() }
waitFor(stubbornHost, "stopped")
require(true, "SIGTERM-resistant child is force-stopped after three seconds")

if CommandLine.arguments.count > 1 {
    let real = ReceiverHost(bundledPath: CommandLine.arguments[1], defaults: defaults)
    real.videoOutput = TestVideoOutput()
    for check in 1...2 {
        let started = Date()
        _ = try real.queue.sync { try real.check(path: "") }
        print("PASS: real dependency check \(check) (fresh then reused registry): \(Date().timeIntervalSince(started)) seconds")
    }
    for cycle in 1...3 {
        try real.queue.sync { try real.start(name: "Airplay Receiver Native Test", path: "") }
        waitFor(real, "waiting", timeout: 15)
        let realPID = real.queue.sync { real.snapshot()["pid"] as! Int32 }
        require(kill(realPID, 0) == 0, "real UxPlay ready cycle \(cycle)")
        real.queue.sync { real.stop() }
        waitFor(real, "stopped")
        require(kill(realPID, 0) == -1, "real UxPlay cleaned cycle \(cycle)")
    }
    real.shutdown()
}
print("All native lifecycle checks passed.")
