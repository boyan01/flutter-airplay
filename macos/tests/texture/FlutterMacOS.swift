// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only module; never linked into Runner.
import CoreVideo
public protocol FlutterTexture: AnyObject {
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?
}
public protocol FlutterTextureRegistry: AnyObject {
    func register(_ texture: FlutterTexture) -> Int64
    func unregisterTexture(_ textureId: Int64)
    func textureFrameAvailable(_ textureId: Int64)
}
