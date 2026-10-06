// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif
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
    private var serial: UInt64 = 0, copiedSerial: UInt64 = 0
    private var reportStart: UInt64 = 0, receivedAt: UInt64 = 0, lastCopyAt: UInt64 = 0
    private var received = 0, copied = 0, overwritten = 0, repeated = 0
    private var maxAge: UInt64 = 0, maxCopyGap: UInt64 = 0, maxNotifyDelay: UInt64 = 0
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
        serial = 0; copiedSerial = 0; reportStart = 0; receivedAt = 0; lastCopyAt = 0
        received = 0; copied = 0; overwritten = 0; repeated = 0
        maxAge = 0; maxCopyGap = 0; maxNotifyDelay = 0
    }
    func receive(_ frame: CVPixelBuffer) {
        lock.lock()
        guard active, !disposed else { lock.unlock(); return }
        let now = DispatchTime.now().uptimeNanoseconds
        if reportStart == 0 { reportStart = now }
        if latest != nil && serial != copiedSerial { overwritten += 1 }
        serial += 1; received += 1; receivedAt = now
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
        let requested = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.maxNotifyDelay = max(self.maxNotifyDelay, DispatchTime.now().uptimeNanoseconds - requested)
            self.notificationPending = false; let valid = !self.disposed
            self.lock.unlock()
            if valid { self.registry.textureFrameAvailable(self.textureIdentifier) }
        }
    }
    func diagnostics() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard reportStart != 0, serial > 0 else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        let text = String(format: "Apple texture stats: interval_ms=%.0f received=%d acquired_new=%d overwritten_before_acquire=%d repeated_acquire=%d pending=%d last_receive_age_ms=%.1f last_acquire_age_ms=%.1f notify_delay_max_ms=%.1f frame_age_max_ms=%.1f acquire_gap_max_ms=%.1f",
            Double(now - reportStart) / 1e6, received, copied, overwritten, repeated, latest != nil && serial != copiedSerial ? 1 : 0,
            Double(now - receivedAt) / 1e6, lastCopyAt == 0 ? -1 : Double(now - lastCopyAt) / 1e6,
            Double(maxNotifyDelay) / 1e6, Double(maxAge) / 1e6, Double(maxCopyGap) / 1e6)
        reportStart = now; received = 0; copied = 0; overwritten = 0; repeated = 0
        maxAge = 0; maxCopyGap = 0; maxNotifyDelay = 0
        return text
    }
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock(); defer { lock.unlock() }
        if latest != nil && serial != copiedSerial {
            let now = DispatchTime.now().uptimeNanoseconds
            copiedSerial = serial; copied += 1
            maxAge = max(maxAge, now - receivedAt)
            if lastCopyAt != 0 { maxCopyGap = max(maxCopyGap, now - lastCopyAt) }
            lastCopyAt = now
        } else if latest != nil { repeated += 1 }
        return latest.map { Unmanaged.passRetained($0) }
    }
}
