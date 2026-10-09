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
    var testMetricsEpoch: UInt64 { metricsEpoch }
    var testSystemMetrics: String? { systemMetrics }
    func testDrain(at presentationTime: CMTime? = nil) { drain(at: presentationTime) }
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
surface.testDrain(at: recoveryTime)
require(surface.testDropped == 6 && surface.testEnqueued == 2 && surface.testPending.isEmpty,
        "Main thread recovery enqueues only the latest missed sample and preserves the future sample")
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
