// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct VideoFrame {
    let width: Int
    let height: Int
    let stride: Int
    let pixels: Data
}

// Each session owns its socket and worker. Pixel payloads never enter Dart or a file.
final class FrameSocketServer {
    private let lock = NSLock()
    private var active = true
    private var client: Int32 = -1
    private var connectionEpoch = 0
    private let listener: Int32
    private let directory: URL
    let path: String
    var onFrame: ((VideoFrame) -> Void)?

    init() throws {
        directory = URL(fileURLWithPath: "/tmp/flutter-airplay-" + UUID().uuidString)
        path = directory.appendingPathComponent("frames.sock").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, Darwin.listen(listener, 1) == 0 else {
            if listener >= 0 { Darwin.close(listener) }
            try? FileManager.default.removeItem(at: directory)
            throw ReceiverFailure(message: "无法创建本地视频通道。")
        }
        chmod(path, 0o600)
    }

    func start() {
        DispatchQueue(label: "org.flutterairplay.frames").async { self.run() }
    }

    private var isActive: Bool {
        lock.lock(); defer { lock.unlock() }; return active
    }

    func stop() {
        lock.lock(); active = false
        if client >= 0 { Darwin.shutdown(client, SHUT_RDWR) }
        lock.unlock()
        // Unlink synchronously: app termination can end the worker before its defer.
        // The listener descriptor is closed by the worker, but is no longer reachable.
        try? FileManager.default.removeItem(at: directory)
    }

    // Drop a disconnected session's partial/in-flight packet while retaining the listener.
    // Delivery holds this lock, so after this returns no old callback can begin.
    func discardConnection() {
        lock.lock(); connectionEpoch += 1
        if client >= 0 { Darwin.shutdown(client, SHUT_RDWR) }
        lock.unlock()
    }

    private func readExact(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { bytes -> Bool in
            var position = 0
            while position < count && isActive {
                let n = Darwin.recv(fd, bytes.baseAddress!.advanced(by: position), count - position, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                position += n
            }
            return position == count
        }
        return ok ? data : nil
    }

    private func run() {
        defer {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)
        }
        while isActive {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 200) > 0 else { continue }
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            lock.lock(); client = fd; let continuing = active; let epoch = connectionEpoch; lock.unlock()
            if continuing { receive(fd, epoch: epoch) }
            lock.lock(); Darwin.close(fd); client = -1; lock.unlock()
        }
    }

    private func receive(_ fd: Int32, epoch: Int) {
        while isActive, let header = readExact(fd, 32) {
            let words = header.withUnsafeBytes { bytes in
                (0..<8).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
            }
            let width = Int(words[2]), height = Int(words[3]), stride = Int(words[4])
            guard words[0] == 0x31565046, words[1] == 1, words[7] == 0,
                  (1...4096).contains(width), (1...4096).contains(height),
                  stride == width * 4, Int(words[5]) == stride * height,
                  let pixels = readExact(fd, stride * height) else { return }
            lock.lock()
            if active && connectionEpoch == epoch {
                onFrame?(VideoFrame(width: width, height: height, stride: stride, pixels: pixels))
            }
            lock.unlock()
        }
    }
}
