// SPDX-License-Identifier: GPL-3.0-or-later
import FlutterMacOS
import CoreVideo
import Foundation

// A bounded latest-frame texture; GStreamer still schedules video with the audio clock.
final class FrameTexture: NSObject, FlutterTexture, ReceiverVideoOutput {
    private let registry: FlutterTextureRegistry
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var server: FrameSocketServer?
    private var generation = 0
    private var notificationPending = false
    private var disposed = false
    private var registered = false
    private var dimensions = (0, 0)
    private var notifiedDimensions = (-1, -1)
    private(set) var textureIdentifier: Int64 = -1
    var onDimensions: ((Int, Int) -> Void)?

    init(registry: FlutterTextureRegistry) {
        self.registry = registry
        super.init()
    }

    // Called by the bridge on the first Dart channel request, after engine startup.
    // Registering in awakeFromNib silently fails because viewWillAppear starts it.
    func register() {
        guard !registered, !disposed else { return }
        textureIdentifier = registry.register(self)
        registered = true
    }

    func begin() throws -> String {
        end()
        lock.lock(); let unavailable = disposed || !registered; lock.unlock()
        guard !unavailable else { throw ReceiverFailure(message: "视频引擎已关闭。") }
        let next = try FrameSocketServer()
        lock.lock(); server = next; let token = generation; lock.unlock()
        next.onFrame = { [weak self] frame in self?.receive(frame, token: token) }
        next.start()
        return next.path
    }

    func clear() {
        lock.lock(); let current = server; lock.unlock()
        current?.discardConnection()
        lock.lock(); latest = nil; dimensions = (0, 0); lock.unlock()
        scheduleNotification()
    }

    func end() {
        lock.lock()
        generation += 1
        let previous = server; server = nil; latest = nil; dimensions = (0, 0)
        lock.unlock()
        previous?.stop()
        scheduleNotification()
    }

    // The bridge calls this on the main thread before destroying/replacing the engine.
    func dispose() {
        end()
        lock.lock(); let wasDisposed = disposed; disposed = true; lock.unlock()
        if !wasDisposed && registered { registry.unregisterTexture(textureIdentifier) }
        onDimensions = nil
    }

    private func scheduleNotification() {
        lock.lock()
        let schedule = !notificationPending && !disposed
        if schedule { notificationPending = true }
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.notificationPending = false
            let size = self.dimensions, valid = !self.disposed
            self.lock.unlock()
            if valid {
                // Drain current state, never a captured old-session frame/dimension.
                if self.notifiedDimensions != size {
                    self.notifiedDimensions = size
                    self.onDimensions?(size.0, size.1)
                }
                self.registry.textureFrameAvailable(self.textureIdentifier)
            }
        }
    }

    private func receive(_ frame: VideoFrame, token: Int) {
        lock.lock(); let current = generation == token && server != nil; lock.unlock()
        guard current else { return }
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                          kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height,
                                  kCVPixelFormatType_32BGRA, attributes, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let destination = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            frame.pixels.withUnsafeBytes { source in
                for row in 0..<frame.height {
                    memcpy(destination.advanced(by: row * stride),
                           source.baseAddress!.advanced(by: row * frame.stride), frame.stride)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        lock.lock()
        guard generation == token, server != nil else { lock.unlock(); return }
        latest = buffer
        dimensions = (frame.width, frame.height)
        lock.unlock()
        scheduleNotification()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock(); defer { lock.unlock() }
        return latest.map { Unmanaged.passRetained($0) }
    }
}
