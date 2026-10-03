// SPDX-License-Identifier: GPL-3.0-or-later
import Flutter
import CoreVideo
import Foundation

// VideoToolbox produces IOSurface-backed buffers consumed directly by Flutter.
final class FrameTexture: NSObject, FlutterTexture, ReceiverVideoOutput {
    private let registry: FlutterTextureRegistry
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var active = false
    private var notificationPending = false
    private var disposed = false
    private var registered = false
    private(set) var textureIdentifier: Int64 = -1

    init(registry: FlutterTextureRegistry) { self.registry = registry; super.init() }
    // Engine registration must follow viewWillAppear / engine startup.
    func register() {
        guard !registered, !disposed else { return }
        textureIdentifier = registry.register(self); registered = true
    }
    func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !disposed, registered else { throw ReceiverFailure(message: "视频引擎已关闭。") }
        latest = nil; active = true
    }
    func receive(_ frame: CVPixelBuffer) {
        lock.lock()
        guard active, !disposed else { lock.unlock(); return }
        latest = frame
        lock.unlock()
        scheduleNotification()
    }
    func clear() { lock.lock(); latest = nil; lock.unlock(); scheduleNotification() }
    func end() { lock.lock(); active = false; latest = nil; lock.unlock(); scheduleNotification() }
    func dispose() {
        end()
        lock.lock(); let previous = disposed; disposed = true; lock.unlock()
        if !previous, registered { registry.unregisterTexture(textureIdentifier) }
    }
    private func scheduleNotification() {
        lock.lock()
        let schedule = !notificationPending && !disposed
        if schedule { notificationPending = true }
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.notificationPending = false; let valid = !self.disposed; self.lock.unlock()
            if valid { self.registry.textureFrameAvailable(self.textureIdentifier) }
        }
    }
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock(); defer { lock.unlock() }
        return latest.map { Unmanaged.passRetained($0) }
    }
}
