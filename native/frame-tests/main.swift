// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

func require(_ condition: Bool, _ detail: String) {
    if !condition { fputs("FAIL: \(detail)\n", stderr); exit(1) }
    print("PASS: \(detail)")
}
let producer = CommandLine.arguments[1]
for cycle in 1...3 {
    let server = try FrameSocketServer()
    let signal = DispatchSemaphore(value: 0)
    let frameLock = NSLock()
    var dimensions = Set<String>()
    var count = 0
    var valid = true
    server.onFrame = { frame in
        frameLock.lock()
        dimensions.insert("\(frame.width)x\(frame.height)")
        count += 1
        valid = valid && frame.pixels.count == frame.width * frame.height * 4 &&
            frame.pixels[0] <= 5 && frame.pixels[1] <= 5 && frame.pixels[2] >= 250 && frame.pixels[3] == 255
        frameLock.unlock()
        signal.signal()
    }
    server.start()
    // Reject oversized dimensions, bad magic/version/reserved, stride/length,
    // truncated headers and partial payloads without poisoning the next connection.
    func sendPacket(_ words: [UInt32], payload: Data = Data()) {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(server.path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        require(connected == 0, "Malformed fixture connected")
        var wire = Data()
        for word in words { var little = word.littleEndian; withUnsafeBytes(of: &little) { wire.append(contentsOf: $0) } }
        wire.append(payload)
        wire.withUnsafeBytes { bytes in _ = Darwin.send(fd, bytes.baseAddress, bytes.count, 0) }
        Darwin.close(fd)
        Thread.sleep(forTimeInterval: 0.03)
    }
    let validHeader: [UInt32] = [0x31565046, 1, 2, 2, 8, 16, 1, 0]
    for (index, value) in [(0, UInt32(0)), (1, 2), (2, 4097), (3, 0), (4, 4), (5, 15), (7, 1)] {
        var words = validHeader; words[index] = value; sendPacket(words)
    }
    sendPacket([0x31565046]); sendPacket(validHeader, payload: Data(repeating: 0, count: 5))
    Thread.sleep(forTimeInterval: 0.1)
    frameLock.lock(); let rejected = count == 0; frameLock.unlock()
    require(rejected, "Malformed/truncated frames rejected")
    for size in [(160, 90), (90, 160)] {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: producer)
        child.arguments = [server.path, String(size.0), String(size.1), "12"]
        try child.run(); child.waitUntilExit()
        require(child.terminationStatus == 0, "Real appsink producer completed")
    }
    let renderer = Process()
    renderer.executableURL = URL(fileURLWithPath: producer)
    renderer.arguments = [server.path, "160", "90", "12", "renderer"]
    try renderer.run(); renderer.waitUntilExit()
    require(renderer.terminationStatus == 0, "Actual UxPlay H264/appsink renderer, two orientations and restart")
    require(signal.wait(timeout: .now() + 2) == .success, "Frames received")
    frameLock.lock()
    let good = valid && count >= 2 && dimensions.count == 2
    frameLock.unlock()
    require(good, "Packed BGRA pixels and portrait/landscape frames, cycle \(cycle)")
    // Interrupt an incomplete frame while keeping the listener usable.
    let partial = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(server.path.utf8) + [0]) }
    _ = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(partial, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    } }
    let words = validHeader.map { $0.littleEndian }
    _ = words.withUnsafeBytes { Darwin.send(partial, $0.baseAddress, $0.count, 0) }
    Thread.sleep(forTimeInterval: 0.05)
    server.discardConnection()
    Darwin.close(partial)
    let reconnect = Process(); reconnect.executableURL = URL(fileURLWithPath: producer)
    reconnect.arguments = [server.path, "160", "90", "6"]
    try reconnect.run(); reconnect.waitUntilExit()
    require(reconnect.terminationStatus == 0, "Partial frame invalidated; same listener reconnects")
    // Stop while recv is waiting for the rest of a payload.
    let stalled = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    _ = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(stalled, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    } }
    _ = words.withUnsafeBytes { Darwin.send(stalled, $0.baseAddress, $0.count, 0) }
    Thread.sleep(forTimeInterval: 0.05)
    server.stop()
    require(!FileManager.default.fileExists(atPath: server.path), "Stop removes socket synchronously before process exit")
    Darwin.close(stalled)
    let deadline = Date().addingTimeInterval(2)
    while FileManager.default.fileExists(atPath: server.path) && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    require(!FileManager.default.fileExists(atPath: server.path), "Owned socket removed after stop")
}
// A reader slower than video must cause bounded sender timeout/drop, never an
// ever-growing queue or streaming-thread stall. Check the packets that survive.
let slow = try FrameSocketServer()
let slowLock = NSLock()
var slowCount = 0, slowValid = true
slow.onFrame = { frame in
    slowLock.lock()
    slowCount += 1
    slowValid = slowValid && frame.pixels.count == frame.stride * frame.height && frame.pixels[2] == 255
    slowLock.unlock()
    Thread.sleep(forTimeInterval: 0.4)
}
slow.start()
let flood = Process(); flood.executableURL = URL(fileURLWithPath: producer)
flood.arguments = [slow.path, "1920", "1080", "60"]
let began = Date()
try flood.run(); flood.waitUntilExit()
require(flood.terminationStatus == 0 && Date().timeIntervalSince(began) < 4, "Slow reader does not stall appsink producer or shutdown")
slow.stop()
require(!FileManager.default.fileExists(atPath: slow.path), "Slow-reader stop removes socket synchronously")
slowLock.lock(); let slowGood = slowValid && slowCount > 0; slowLock.unlock()
require(slowGood, "Slow reader receives complete BGRA packets across sender timeout/reconnect")
let cleanupDeadline = Date().addingTimeInterval(2)
while FileManager.default.fileExists(atPath: slow.path) && Date() < cleanupDeadline { Thread.sleep(forTimeInterval: 0.01) }
require(!FileManager.default.fileExists(atPath: slow.path), "Slow reader socket removed")
print("All native appsink → Swift frame transport checks passed. No iPhone claimed.")
