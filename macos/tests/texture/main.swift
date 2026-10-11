// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreVideo
import FlutterMacOS
func require(_ value: Bool, _ detail: String) {
    if !value { fputs("FAIL: \(detail)\n", stderr); exit(1) }
    print("PASS: \(detail)")
}
final class Registry: FlutterTextureRegistry {
    var notifications = 0, removals = 0, registrations = 0
    func register(_ texture: FlutterTexture) -> Int64 { registrations += 1; return 0 }
    func unregisterTexture(_ textureId: Int64) { removals += 1 }
    func textureFrameAvailable(_ textureId: Int64) { notifications += 1 }
}
let registry = Registry()
let texture = FrameTexture(registry: registry)
require(registry.registrations == 0, "Nib construction defers registration until engine startup")
texture.register(); texture.register()
require(registry.registrations == 1, "Register exactly once")
try texture.begin()
var buffer: CVPixelBuffer?
let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
require(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, "Synthetic IOSurface buffer")
texture.receive(buffer!)
require(texture.copyPixelBuffer()!.takeRetainedValue() === buffer!, "Flutter retains decoder buffer without pixel copy")
texture.clear()
require(texture.copyPixelBuffer() == nil, "FLUSH clears old pixels")
texture.end(); texture.receive(buffer!)
require(texture.copyPixelBuffer() == nil, "Stopped texture rejects frames")
try texture.begin(); texture.receive(buffer!)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
require(registry.notifications == 1 && texture.copyPixelBuffer() != nil, "Notifications coalesce and use current session")
texture.dispose(); texture.dispose()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
require(registry.removals == 1 && texture.copyPixelBuffer() == nil, "Engine disposal clears buffer and unregisters once")
do { try texture.begin(); require(false, "Disposed texture accepted restart") } catch {}

extension VideoSurface {
    var testPending: [CMSampleBuffer] { pending }
    var testEnqueued: Int { submitted }
    var testDropped: Int { dropped }
    var testRecoveries: Int { recoveries }
    var testRenderReady: Bool { renderReady }
    var testRenderFailed: Bool { renderStatus == .failed }
    var testRecoveryState: String {
        "dropped=\(dropped) enqueued=\(submitted) pending=\(pending.count) ready=\(renderReady) status=\(renderStatus.rawValue) error=\(renderError ?? "none")"
    }
    var testMetricsEpoch: UInt64 { metricsEpoch }
    var testSystemMetrics: String? { systemMetrics }
    func testDrain(at presentationTime: CMTime? = nil, ready: Bool? = nil) {
        drain(at: presentationTime, readyOverride: ready)
    }
    func testSetPresentationTimes(_ times: [CMTime]) {
        require(times.count == pending.count, "Recovery timeline covers every pending sample")
        pending = zip(pending, times).map { sample, pts in
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
            require(status == noErr && copy != nil, "Recovery sample accepts a fixed presentation time")
            return copy!
        }
    }
}
func deadlineAfter(_ nanoseconds: Int64) -> Int64 {
    var now = timespec(); clock_gettime(CLOCK_MONOTONIC, &now)
    return Int64(now.tv_sec) * 1_000_000_000 + Int64(now.tv_nsec) + nanoseconds
}
let croppedSurface = VideoSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
let controls = NSView(frame: croppedSurface.bounds)
controls.autoresizingMask = [.width, .height]
croppedSurface.addSubview(controls)
let cropArguments: [String: Any] = ["left": 0.25, "top": 0.1, "width": 0.5, "height": 0.5,
                                    "sourceWidth": 1920, "sourceHeight": 1080]
require(VideoPresentation(arguments: cropArguments) != nil, "Normalized crop accepts optional source dimensions")
let roundingArguments: [String: Any] = ["left": 0.25, "top": 0.1, "width": 0.75 + 5e-10, "height": 0.9 + 5e-10]
require(VideoPresentation(arguments: roundingArguments)?.crop == CGRect(x: 0.25, y: 0.1, width: 0.75, height: 0.9),
        "Boundary rounding within tolerance clamps crop to the video frame")
for (key, value) in [("width", 0.75 + 2e-9), ("height", 0.9 + 2e-9), ("left", 1.0), ("top", 1.0)] {
    var invalid = roundingArguments
    invalid[key] = value
    require(VideoPresentation(arguments: invalid) == nil, "Out-of-bounds crops beyond rounding tolerance remain invalid")
}
for invalid: [String: Any] in [
    ["left": -0.1, "top": 0, "width": 1, "height": 1],
    ["left": 0, "top": 0, "width": 0, "height": 1],
    ["left": 0.5, "top": 0, "width": 0.6, "height": 1],
    ["left": false, "top": 0, "width": 1, "height": 1],
    ["left": 0, "top": 0, "width": Double.nan, "height": 1],
    ["left": 0, "top": 0, "width": 1, "height": 1, "sourceWidth": 100],
] {
    require(VideoPresentation(arguments: invalid) == nil, "Invalid crop is rejected before changing layers")
}
croppedSurface.setVideoPresentation(VideoPresentation(arguments: cropArguments)!)
let viewport = croppedSurface.displayLayer.superlayer!
require(viewport.masksToBounds && viewport.frame == CGRect(x: 0, y: 75, width: 800, height: 450),
        "Crop aspect fits inside a dedicated viewport")
require(abs(croppedSurface.displayLayer.frame.minX + 400) < 0.001 &&
        abs(croppedSurface.displayLayer.frame.minY + 360) < 0.001 &&
        croppedSurface.displayLayer.frame.size == CGSize(width: 1600, height: 900),
        "Full video expands proportionally with top-left crop converted to AppKit")
require(controls.frame == croppedSurface.bounds && croppedSurface.layer?.masksToBounds == false,
        "Video clipping does not clip Flutter controls")
croppedSurface.setFrameSize(NSSize(width: 400, height: 600))
croppedSurface.layout()
require(viewport.frame.size == CGSize(width: 400, height: 225), "Window resize reapplies crop geometry")
var portraitFallback = cropArguments
portraitFallback["sourceWidth"] = 1080
portraitFallback["sourceHeight"] = 1920
croppedSurface.setVideoPresentation(VideoPresentation(arguments: portraitFallback)!)
require(abs(viewport.frame.width - 337.5) < 0.001 && abs(viewport.frame.height - 600) < 0.001,
        "Fallback source dimensions determine crop aspect before decoded frames arrive")
try croppedSurface.begin()
croppedSurface.receive(buffer!, deadline: deadlineAfter(120_000_000))
croppedSurface.testDrain()
require(viewport.frame.size == CGSize(width: 400, height: 225), "Native decoded frame dimensions override fallback dimensions")
croppedSurface.setVideoPresentation(VideoPresentation())
require(croppedSurface.displayLayer.frame == viewport.bounds, "Default crop restores the full video without restarting playback")
var editingArguments = cropArguments
editingArguments["viewportLeft"] = 0.1
editingArguments["viewportTop"] = 0.2
editingArguments["viewportWidth"] = 0.8
editingArguments["viewportHeight"] = 0.6
croppedSurface.setVideoPresentation(VideoPresentation(arguments: editingArguments)!)
require(viewport.frame == CGRect(x: 40, y: 210, width: 320, height: 180),
        "Editor viewport reserves top and bottom controls with a top-left origin")
require(controls.frame == croppedSurface.bounds, "Editor viewport leaves Flutter controls in place")
for (key, value) in [("viewportTop", -0.1), ("viewportHeight", 0.9), ("viewportWidth", 0.0)] {
    var invalid = editingArguments
    invalid[key] = value
    require(VideoPresentation(arguments: invalid) == nil, "Invalid editor viewport is rejected")
}
croppedSurface.dispose()

let surface = VideoSurface(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
require(surface.textureIdentifier == -1 && surface.displayLayer.controlTimebase != nil,
        "Native display uses a host timebase without a Flutter texture")
try surface.begin()
surface.receive(buffer!, deadline: deadlineAfter(120_000_000))
require(surface.testPending.count == 1 && CMSampleBufferGetImageBuffer(surface.testPending[0]) === buffer!,
        "Native sample retains the decoded image without copying pixels")
let timeLeft = CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(surface.testPending[0]),
    CMClockGetTime(CMClockGetHostTimeClock())))
require(timeLeft > 0.10 && timeLeft <= 0.12, "Presentation deadline maps to host clock without immediate display")
for _ in 0..<30 { surface.receive(buffer!, deadline: deadlineAfter(120_000_000)) }
require(surface.testPending.count == 16, "Busy main thread retains at most sixteen samples")
surface.end()
require(surface.testPending.isEmpty, "Stop releases all pending display samples")
surface.receive(buffer!, deadline: deadlineAfter(120_000_000))
require(surface.testPending.isEmpty, "Stopped surface rejects output")
try surface.begin()
surface.receive(buffer!, deadline: deadlineAfter(120_000_000))
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
require(surface.testPending.isEmpty && surface.displayLayer.status != .failed,
        "Restart enqueues a new sample after clearing obsolete output")
surface.receive(buffer!, deadline: deadlineAfter(-300_000_000))
surface.testDrain()
require(surface.testPending.isEmpty && surface.diagnostics()!.contains("dropped=1"),
        "Main thread stalls discard expired decoded samples")
try surface.begin(); surface.testDrain()
// Freeze both sample PTS and drain time so runner stalls cannot expire the future
// sample or age the latest missed sample beyond the 150 ms discard threshold.
let recoveryTime = CMClockGetTime(CMClockGetHostTimeClock())
let recoveryTimes = (0..<7).map {
    CMTimeAdd(recoveryTime, CMTime(value: -100 + Int64($0) * 16, timescale: 1_000))
} + [CMTimeAdd(recoveryTime, CMTime(value: 500, timescale: 1_000))]
for _ in recoveryTimes { surface.receive(buffer!, deadline: deadlineAfter(0)) }
surface.testSetPresentationTimes(recoveryTimes)
require(surface.testPending.dropLast().allSatisfy {
    CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), recoveryTime) < 0
} && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(surface.testPending.last!), recoveryTime) > 0,
        "Recovery timeline contains seven missed samples and one future sample")
let recoverySurvivors = Array(surface.testPending.suffix(2))
surface.testDrain(at: recoveryTime)
require(surface.testDropped == 6 && surface.testEnqueued <= 2 &&
        surface.testPending.count == 2 - surface.testEnqueued &&
        zip(surface.testPending, recoverySurvivors.dropFirst(surface.testEnqueued)).allSatisfy { $0 === $1 },
        "Recovery coalesces six missed samples and retains unsubmitted survivors (\(surface.testRecoveryState))")
// Renderer backpressure can leave either survivor pending after the first drain.
// Keep the main run loop blocked so scheduled real-time drains cannot race this
// fixed-time fixture. Renderer readiness progresses on its own queue.
let readinessDeadline = ProcessInfo.processInfo.systemUptime + 5
while !surface.testPending.isEmpty && !surface.testRenderFailed &&
      ProcessInfo.processInfo.systemUptime < readinessDeadline {
    if surface.testRenderReady {
        surface.testDrain(at: recoveryTime)
    } else {
        Thread.sleep(forTimeInterval: 0.005)
    }
}
require(surface.testDropped == 6 && surface.testEnqueued == 2 && surface.testPending.isEmpty,
        "Main thread recovery enqueues only the latest missed sample and preserves the future sample (\(surface.testRecoveryState))")
if #available(macOS 14.4, *) {
    let epoch = surface.testMetricsEpoch
    let report = surface.diagnostics()!
    require(report.contains("system_metrics=unavailable"), "Unmeasured system display metrics remain explicitly unavailable")
    surface.clear()
    require(surface.testMetricsEpoch != epoch && surface.testSystemMetrics == nil,
            "Flush invalidates outstanding system metric snapshots")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    require(surface.testSystemMetrics == nil, "Old-session metric request cannot repopulate cleared diagnostics")
    surface.testDrain()
    _ = surface.diagnostics()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let sample = surface.diagnostics()!
    require(sample.contains("system_total_frames=") || sample.contains("system_metrics=unavailable"),
            "Asynchronous system sampling returns a snapshot or explicitly unavailable metrics")
}
// Reproduce a live renderer which keeps reporting backpressure after its
// queue emptied. New decoded frames must not be discarded forever.
require(surface.testRecoveries == 0, "Normal playback and main thread coalescing do not reset the renderer")
try surface.begin(); surface.testDrain()
let blockedTime = CMClockGetTime(CMClockGetHostTimeClock())
var displayLogs: [String] = []
surface.onLog = { displayLogs.append($0) }
for step in 0...10 {
    let now = CMTimeAdd(blockedTime, CMTime(value: Int64(step), timescale: 10))
    surface.receive(buffer!, deadline: deadlineAfter(0))
    surface.testSetPresentationTimes(Array(repeating: now, count: surface.testPending.count))
    surface.testDrain(at: now, ready: false)
    if step < 10 { require(surface.testEnqueued == 0, "Transient backpressure does not trigger recovery") }
}
require(surface.testEnqueued == 1, "Persistent display backpressure resumes bounded live submission")
require(surface.testRecoveries == 1 && displayLogs.contains {
    $0.contains("reason=backpressure") && $0.contains("blocked_ms=") && $0.contains("requires_flush=") && $0.contains("timebase_rate=")
}, "Display recovery records its trigger and renderer/clock state")
let cooldownTime = CMTimeAdd(blockedTime, CMTime(value: 11, timescale: 10))
surface.receive(buffer!, deadline: deadlineAfter(0))
surface.testSetPresentationTimes(Array(repeating: cooldownTime, count: surface.testPending.count))
surface.testDrain(at: cooldownTime, ready: false)
require(surface.testEnqueued == 1 && surface.testRecoveries == 1, "Persistent backpressure cannot flush on every frame")
surface.clear(); surface.testDrain()
let future = CMTimeAdd(blockedTime, CMTime(value: 3, timescale: 1))
surface.receive(buffer!, deadline: deadlineAfter(0))
surface.testSetPresentationTimes([future])
surface.testDrain(at: blockedTime, ready: false)
surface.testDrain(at: CMTimeAdd(blockedTime, CMTime(value: 2, timescale: 1)), ready: false)
require(surface.testRecoveries == 1 && surface.testPending.count == 1,
        "A future sample alone does not trigger a display reset")
// Expiring the last pending sample means there is no live input to recover.
surface.testDrain(at: CMTimeAdd(blockedTime, CMTime(value: 4, timescale: 1)), ready: false)
surface.receive(buffer!, deadline: deadlineAfter(0))
let resumed = CMTimeAdd(blockedTime, CMTime(value: 5, timescale: 1))
surface.testSetPresentationTimes([resumed])
surface.testDrain(at: resumed, ready: false)
require(surface.testRecoveries == 1, "Input inactivity resets the blocked timer before new video arrives")
let stalledReport = surface.diagnostics()!
require(stalledReport.contains("last_enqueue_age_ms=") && stalledReport.contains("main_queue_wait_ms=") &&
        stalledReport.contains("state_sample_age_ms=") && stalledReport.contains("expired_drop="),
        "Frozen display diagnostics retain progress ages, main queue delay and drop reasons")
surface.clear(); surface.testDrain()
var yuv: CVPixelBuffer?
require(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    attributes, &yuv) == kCVReturnSuccess, "Synthetic NV12 display buffer")
CVBufferSetAttachment(yuv!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
surface.receive(yuv!, deadline: deadlineAfter(120_000_000))
let format = CMSampleBufferGetFormatDescription(surface.testPending[0])!
let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
require(matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
        "Native sample preserves the decoder's BT.709 color metadata")
surface.dispose(); surface.testDrain()
do { try surface.begin(); require(false, "Disposed surface accepted restart") } catch {}
