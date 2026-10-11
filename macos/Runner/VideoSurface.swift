// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import AVFoundation

// The Flutter view is a transparent sibling above this layer. Only metadata is
// wrapped in CMSampleBuffer; decoder pixel buffers remain IOSurface-backed.
final class VideoSurface: NSView, ReceiverVideoOutput {
    let displayLayer = AVSampleBufferDisplayLayer()
    let textureIdentifier: Int64 = -1
    var onError: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    private let lock = NSLock()
    private var active = false, disposed = false, scheduled = false, needsFlush = false
    private var pending: [CMSampleBuffer] = []
    private var received = 0, submitted = 0, dropped = 0
    private var overflowDrops = 0, expiredDrops = 0, coalescedDrops = 0, recoveries = 0
    private var blockedSince: Double?
    private var lastRecovery: Double?
    private var lastReceive: Double?, lastEnqueue: Double?, lastDrain: Double?
    private var scheduledAt = 0.0, maxDrainDelay = 0.0
    private var displayState = "renderer_state=unmeasured"
    private var displayStateAt: Double?
    private var frameWidth = 0, frameHeight = 0
    private var pixelFormat: OSType = 0
    private var failureReported = false
    private var failureObserver: NSObjectProtocol?
    private var clockReady = false
    private var metricsEpoch: UInt64 = 0
    private var systemMetrics: String?
    private var metricsSampledAt: TimeInterval = 0

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
                    let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                    self.displayState = self.displayStateLocked(at: now); self.displayStateAt = now
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
        overflowDrops = 0; expiredDrops = 0; coalescedDrops = 0; recoveries = 0
        blockedSince = nil; lastRecovery = nil; lastReceive = nil; lastEnqueue = nil; lastDrain = nil
        maxDrainDelay = 0; displayState = "renderer_state=unmeasured"; displayStateAt = nil
        resetMetricsLocked()
        onLog?("Apple native display begin: epoch=\(metricsEpoch) clock_ready=\(clockReady)")
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
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let pts = CMTimeAdd(hostNow,
            CMTime(value: remaining, timescale: 1_000_000_000))
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleStatus: OSStatus = -1
        if formatStatus == noErr, let format = format {
            sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        }
        guard formatStatus == noErr, sampleStatus == noErr, let sample = sample else {
            reportFailureLocked("Cannot wrap decoded video frame for native display: format_status=\(formatStatus) sample_status=\(sampleStatus) size=\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame)) pixel_format=\(CVPixelBufferGetPixelFormatType(frame))")
            return
        }
        received += 1
        lastReceive = CMTimeGetSeconds(hostNow)
        frameWidth = CVPixelBufferGetWidth(frame); frameHeight = CVPixelBufferGetHeight(frame)
        pixelFormat = CVPixelBufferGetPixelFormatType(frame)
        // Bound retained pixels even if the AppKit main thread is temporarily busy.
        if pending.count == 16 { pending.removeFirst(); dropped += 1; overflowDrops += 1 }
        pending.append(sample)
        scheduleLocked()
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        resetMetricsLocked()
        pending.removeAll(); needsFlush = true; scheduleLocked()
    }
    func end() {
        lock.lock(); defer { lock.unlock() }
        resetMetricsLocked()
        active = false; pending.removeAll(); needsFlush = true; scheduleLocked()
    }
    func dispose() {
        lock.lock(); defer { lock.unlock() }
        resetMetricsLocked()
        active = false; disposed = true; pending.removeAll(); needsFlush = true; scheduleLocked()
    }
    private func scheduleLocked() {
        guard !scheduled else { return }
        scheduled = true
        scheduledAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }
    private func reportFailureLocked(_ detail: String) {
        guard !failureReported else { return }
        failureReported = true; pending.removeAll()
        onLog?("Apple native display failed: \(detail) \(displayState)")
        // This callback only enqueues a receiver command; it must not wait for stop.
        onError?(detail)
    }
    private var renderStatus: AVQueuedSampleBufferRenderingStatus {
        if #available(macOS 14.0, *) { return displayLayer.sampleBufferRenderer.status }
        return displayLayer.status
    }
    private var renderError: String? {
        let error: Error?
        if #available(macOS 14.0, *) { error = displayLayer.sampleBufferRenderer.error }
        else { error = displayLayer.error }
        return error.map { let value = $0 as NSError; return "\(value.domain):\(value.code):\(value.localizedDescription)" }
    }
    private var renderReady: Bool {
        if #available(macOS 14.0, *) { return displayLayer.sampleBufferRenderer.isReadyForMoreMediaData }
        return displayLayer.isReadyForMoreMediaData
    }
    private var renderRequiresFlush: Bool {
        if #available(macOS 14.0, *) { return displayLayer.sampleBufferRenderer.requiresFlushToResumeDecoding }
        if #available(macOS 11.0, *) { return displayLayer.requiresFlushToResumeDecoding }
        return false
    }
    // Read AppKit and renderer properties only on the main thread. Diagnostics
    // publishes this cached snapshot, including its age, without waiting on UI.
    private func displayStateLocked(at now: Double) -> String {
        let timebase = displayLayer.controlTimebase
        let rate = timebase.map { CMTimebaseGetRate($0) } ?? 0
        let drift = timebase.map { (CMTimeGetSeconds(CMTimebaseGetTime($0)) - now) * 1000 } ?? .nan
        return "ready=\(renderReady) status=\(renderStatus.rawValue) requires_flush=\(renderRequiresFlush) error=\(renderError ?? "none") timebase_rate=\(rate) timebase_host_delta_ms=\(String(format: "%.1f", drift)) window_visible=\(window?.isVisible ?? false) minimized=\(window?.isMiniaturized ?? false) occluded=\(!(window?.occlusionState.contains(.visible) ?? false)) bounds=\(Int(bounds.width))x\(Int(bounds.height)) display=\(window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "none")"
    }
    private func drain(at presentationTime: CMTime? = nil, readyOverride: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        let uptime = ProcessInfo.processInfo.systemUptime
        if scheduled { maxDrainDelay = max(maxDrainDelay, uptime - scheduledAt) }
        scheduled = false
        if needsFlush {
            onLog?("Apple native display flush: epoch=\(metricsEpoch) active=\(active) disposed=\(disposed) pending=\(pending.count)")
            displayLayer.flushAndRemoveImage(); needsFlush = false; blockedSince = nil
        }
        guard active, !disposed else { return }
        let now = presentationTime ?? CMClockGetTime(CMClockGetHostTimeClock())
        let seconds = CMTimeGetSeconds(now)
        lastDrain = seconds
        if renderStatus == .failed {
            displayState = displayStateLocked(at: seconds)
            displayStateAt = seconds
            reportFailureLocked(renderError ?? "Native video display failed")
            return
        }
        while !pending.isEmpty {
            // The main thread can stall after scheduler handoff. Coalesce only
            // missed samples here as well; preserve all future presentation times.
            if pending.count > 1,
               CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(pending[1]), now) <= 0 {
                pending.removeFirst(); dropped += 1; coalescedDrops += 1; continue
            }
            if CMTimeGetSeconds(CMTimeSubtract(now, CMSampleBufferGetPresentationTimeStamp(pending[0]))) > 0.15 {
                pending.removeFirst(); dropped += 1; expiredDrops += 1; continue
            }
            let ready = readyOverride ?? renderReady
            if !ready {
                if blockedSince == nil { blockedSince = seconds }
                // A live source must not wait forever on renderer readiness.
                // Recover only with a current frame, at most once a second.
                let lead = CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(pending[0]), now))
                guard seconds - blockedSince! >= 1, lead <= 0.1,
                      lastRecovery.map({ seconds - $0 >= 1 }) ?? true else { break }
                recoveries += 1; lastRecovery = seconds
                onLog?("Apple native display recovery: reason=backpressure count=\(recoveries) blocked_ms=\(String(format: "%.1f", (seconds - blockedSince!) * 1000)) pending=\(pending.count) lead_ms=\(String(format: "%.1f", lead * 1000)) \(displayStateLocked(at: seconds))")
                // Keep the last visible image. All queued input here is already
                // decoded pixels; no codec references or audio clocks are reset.
                if #available(macOS 14.0, *) { displayLayer.sampleBufferRenderer.flush() }
                else { displayLayer.flush() }
                blockedSince = seconds
            } else { blockedSince = nil }
            let sample = pending.removeFirst()
            if #available(macOS 14.0, *) { displayLayer.sampleBufferRenderer.enqueue(sample) }
            else { displayLayer.enqueue(sample) }
            submitted += 1
            lastEnqueue = seconds
            if !ready { break } // One live sample is safe even while readiness is false.
        }
        if pending.isEmpty { blockedSince = nil }
        if !pending.isEmpty {
            scheduled = true
            scheduledAt = uptime + 0.005
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in self?.drain() }
        }
    }
    func diagnostics() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard received > 0 else { return nil }
        let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        func age(_ time: Double?) -> String { time.map { String(format: "%.1f", (now - $0) * 1000) } ?? "-1" }
        let headLead = pending.first.map { String(format: "%.1f", (CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)) - now) * 1000) } ?? "none"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.displayState = self.displayStateLocked(at: CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))
            self.displayStateAt = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        }
        var metrics = "system_metrics=unsupported"
        if #available(macOS 14.4, *) {
            // ReceiverHost requests diagnostics every five seconds. The system
            // snapshot is asynchronous; publish its age and never block playback.
            metrics = systemMetrics.map {
                "\($0) system_sample_age_ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - metricsSampledAt) * 1000))"
            } ?? "system_metrics=unavailable"
            let epoch = metricsEpoch
            if active && !disposed {
                DispatchQueue.main.async { [weak self] in self?.sampleMetrics(epoch: epoch) }
            }
        }
        let delay = maxDrainDelay * 1000; maxDrainDelay = 0
        let waiting = scheduled ? max(0, ProcessInfo.processInfo.systemUptime - scheduledAt) * 1000 : 0
        let frameSize = "\(frameWidth)x\(frameHeight) pixel_format=\(pixelFormat)"
        return "Apple native display stats: epoch=\(metricsEpoch) active=\(active) received=\(received) enqueued=\(submitted) dropped=\(dropped) pending=\(pending.count) overflow_drop=\(overflowDrops) expired_drop=\(expiredDrops) coalesced_drop=\(coalescedDrops) recoveries=\(recoveries) last_receive_age_ms=\(age(lastReceive)) last_enqueue_age_ms=\(age(lastEnqueue)) last_drain_age_ms=\(age(lastDrain)) blocked_ms=\(age(blockedSince)) head_lead_ms=\(headLead) max_main_queue_delay_ms=\(String(format: "%.1f", delay)) main_queue_wait_ms=\(String(format: "%.1f", waiting)) frame=\(frameSize) state_sample_age_ms=\(age(displayStateAt)) \(displayState) \(metrics)"
    }
    private func resetMetricsLocked() {
        metricsEpoch &+= 1; systemMetrics = nil; metricsSampledAt = 0
    }
    @available(macOS 14.4, *)
    private func sampleMetrics(epoch: UInt64) {
        lock.lock()
        let valid = active && !disposed && !needsFlush && metricsEpoch == epoch
        lock.unlock()
        guard valid else { return }
        displayLayer.sampleBufferRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.active, !self.disposed, self.metricsEpoch == epoch else { return }
            self.metricsSampledAt = ProcessInfo.processInfo.systemUptime
            self.systemMetrics = metrics.map {
                "system_total_frames=\($0.totalNumberOfFrames) system_dropped_frames=\($0.numberOfDroppedFrames) system_corrupted_frames=\($0.numberOfCorruptedFrames) system_accumulated_delay_ms=\(String(format: "%.3f", $0.totalAccumulatedFrameDelay * 1000))"
            }
        }
    }
}
