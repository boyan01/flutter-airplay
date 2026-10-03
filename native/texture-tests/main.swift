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
let output = FrameTexture(registry: registry)
require(registry.registrations == 0, "Nib construction does not register against an unstarted engine")
output.register(); output.register()
require(registry.registrations == 1, "First Dart request registers exactly once")
var sizes = [(Int, Int)]()
output.onDimensions = { sizes.append(($0, $1)) }
func feed(_ path: String, _ width: Int, _ height: Int) {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    child.arguments = [path, String(width), String(height), "6"]
    try! child.run(); child.waitUntilExit()
    require(child.terminationStatus == 0, "Synthetic producer")
}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
let path = try output.begin()
feed(path, 160, 90)
require(output.copyPixelBuffer()?.takeRetainedValue() != nil, "IOSurface BGRA buffer created")
output.clear(); drain()
require(output.copyPixelBuffer() == nil && sizes.last!.0 == 0, "Clear rejects queued old-frame notification")
let second = try output.begin()
feed(second, 90, 160)
output.end()
let third = try output.begin()
feed(third, 160, 90)
drain()
require(sizes.last!.0 == 160 && sizes.last!.1 == 90 && registry.notifications > 0, "Pending notification drains new generation, including texture ID zero")
let buffer = output.copyPixelBuffer()!.takeRetainedValue()
CVPixelBufferLockBaseAddress(buffer, .readOnly)
let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
require(bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 255 && bytes[3] == 255, "Actual CVPixelBuffer has red BGRA pixels")
CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
output.dispose(); output.dispose(); drain()
require(registry.removals == 1 && output.copyPixelBuffer() == nil, "Engine disposal unregisters exactly once and clears pixels")
do { _ = try output.begin(); require(false, "Disposed engine rejects restart") } catch { print("PASS: Disposed engine rejects restart") }
