// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import AVFoundation

// The Flutter view is a transparent sibling above this layer. Only metadata is
// wrapped in CMSampleBuffer; decoder pixel buffers remain IOSurface-backed.
final class VideoSurface: NSView, ReceiverVideoOutput {
    let displayLayer = AVSampleBufferDisplayLayer()
    let textureIdentifier: Int64 = -1
    var onError: ((String) -> Void)?
    private let lock = NSLock()
    private var active = false, disposed = false, scheduled = false, needsFlush = false
    private var pending: [CMSampleBuffer] = []
    private var received = 0, submitted = 0, dropped = 0
    private var failureReported = false
    private var failureObserver: NSObjectProtocol?
    private var clockReady = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if status == noErr, let timebase = timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
            clockReady = true
        }
        let name: Notification.Name
        let object: AnyObject
        if #available(macOS 14.0, *) {
            name = AVSampleBufferVideoRenderer.didFailToDecodeNotification
            object = displayLayer.sampleBufferRenderer
        } else {
            name = .AVSampleBufferDisplayLayerFailedToDecode
            object = displayLayer
        }
        failureObserver = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            // Enqueue can post synchronously while drain holds the lock.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                if self.active && !self.needsFlush && self.renderStatus == .failed {
                    self.reportFailureLocked(self.renderError ?? "Native video display failed")
                }
            }
        }
    }
    deinit { if let observer = failureObserver { NotificationCenter.default.removeObserver(observer) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
    func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !disposed, clockReady else {
            throw ReceiverFailure(message: "Native video display is unavailable")
        }
        pending.removeAll(); needsFlush = true; active = true; failureReported = false
        received = 0; submitted = 0; dropped = 0
        scheduleLocked()
    }
    func receive(_ frame: CVPixelBuffer, deadline: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard active, !disposed, !failureReported else { return }
        var format: CMVideoFormatDescription?
        var sample: CMSampleBuffer?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: frame, formatDescriptionOut: &format)
        // CLOCK_MONOTONIC and CoreMedia host time need not have the same epoch.
        var now = timespec(); clock_gettime(CLOCK_MONOTONIC, &now)
        let remaining = deadline - (Int64(now.tv_sec) * 1_000_000_000 + Int64(now.tv_nsec))
        let pts = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
            CMTime(value: remaining, timescale: 1_000_000_000))
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        guard formatStatus == noErr, let format = format,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample = sample else {
            reportFailureLocked("Cannot wrap decoded video frame for native display")
            return
        }
        received += 1
        // Bound retained pixels even if the AppKit main thread is temporarily busy.
        if pending.count == 16 { pending.removeFirst(); dropped += 1 }
        pending.append(sample)
        scheduleLocked()
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(); needsFlush = true; scheduleLocked()
    }
    func end() {
        lock.lock(); defer { lock.unlock() }
        active = false; pending.removeAll(); needsFlush = true; scheduleLocked()
    }
    func dispose() {
        lock.lock(); defer { lock.unlock() }
        active = false; disposed = true; pending.removeAll(); needsFlush = true; scheduleLocked()
    }
    private func scheduleLocked() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }
    private func reportFailureLocked(_ detail: String) {
        guard !failureReported else { return }
        failureReported = true; pending.removeAll()
        // This callback only enqueues a receiver command; it must not wait for stop.
        onError?(detail)
    }
    private var renderStatus: AVQueuedSampleBufferRenderingStatus {
        if #available(macOS 14.0, *) { return displayLayer.sampleBufferRenderer.status }
        return displayLayer.status
    }
    private var renderError: String? {
        if #available(macOS 14.0, *) { return displayLayer.sampleBufferRenderer.error?.localizedDescription }
        return displayLayer.error?.localizedDescription
    }
    private func drain() {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        if needsFlush { displayLayer.flushAndRemoveImage(); needsFlush = false }
        guard active, !disposed else { return }
        if renderStatus == .failed {
            reportFailureLocked(renderError ?? "Native video display failed")
            return
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        while !pending.isEmpty {
            if CMTimeGetSeconds(CMTimeSubtract(now, CMSampleBufferGetPresentationTimeStamp(pending[0]))) > 0.15 {
                pending.removeFirst(); dropped += 1; continue
            }
            let ready: Bool
            if #available(macOS 14.0, *) { ready = displayLayer.sampleBufferRenderer.isReadyForMoreMediaData }
            else { ready = displayLayer.isReadyForMoreMediaData }
            guard ready else { break }
            let sample = pending.removeFirst()
            if #available(macOS 14.0, *) { displayLayer.sampleBufferRenderer.enqueue(sample) }
            else { displayLayer.enqueue(sample) }
            submitted += 1
        }
        if !pending.isEmpty {
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in self?.drain() }
        }
    }
    func diagnostics() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard received > 0 else { return nil }
        return "Apple native display stats: received=\(received) enqueued=\(submitted) dropped=\(dropped) pending=\(pending.count)"
    }
}
