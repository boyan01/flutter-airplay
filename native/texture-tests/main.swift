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
