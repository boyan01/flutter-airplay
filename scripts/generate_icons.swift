#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Run from the repository root: swift scripts/generate_icons.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("assets/app_icon/receiver_mark.png")
let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
let original = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func canvas(_ width: Int, _ height: Int, opaque: Bool = false) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: colorSpace,
                            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast
                                                : CGImageAlphaInfo.premultipliedLast).rawValue)!
    context.interpolationQuality = .high
    return context
}

// Trim transparent padding so all platforms share the same optical size.
let probe = canvas(original.width, original.height)
probe.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
let pixels = probe.data!.assumingMemoryBound(to: UInt8.self)
var left = original.width, right = 0, top = original.height, bottom = 0
for y in 0..<original.height {
    for x in 0..<original.width where pixels[(y * original.width + x) * 4 + 3] >= 128 {
        left = min(left, x); right = max(right, x)
        top = min(top, y); bottom = max(bottom, y)
    }
}
let mark = original.cropping(to: CGRect(x: left, y: top,
                                      width: right - left + 1, height: bottom - top + 1))!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red / 255, green / 255, blue / 255, 1])!
}

let tealTop = color(50, 149, 138)
let tealBottom = color(18, 75, 70)
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: [tealTop, tealBottom] as CFArray, locations: [0, 1])!

func background(_ context: CGContext, _ rect: CGRect) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
}

func symbol(_ context: CGContext, center: CGPoint, width: CGFloat) {
    let height = width * CGFloat(mark.height) / CGFloat(mark.width)
    context.draw(mark, in: CGRect(x: center.x - width / 2, y: center.y - height / 2,
                                 width: width, height: height))
}

func tile(_ context: CGContext, size: CGFloat, inset: CGFloat, shadow: Bool) {
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225,
                      cornerHeight: rect.height * 0.225, transform: nil)
    if shadow {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.008),
                          blur: size * 0.016, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        context.setFillColor(tealBottom)
        context.addPath(path); context.fillPath()
        context.restoreGState()
    }
    context.saveGState()
    context.addPath(path); context.clip()
    background(context, rect)
    symbol(context, center: CGPoint(x: size / 2, y: size / 2), width: rect.width * 0.68)
    context.restoreGState()
}

func save(_ context: CGContext, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination), "Could not write \(path)")
}

// iPhone and iPad share the existing asset catalog, including App Store artwork.
// Supply opaque square artwork; the operating system applies its own mask.
let iosDirectory = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
let catalogData = try Data(contentsOf: root.appendingPathComponent("\(iosDirectory)/Contents.json"))
let catalog = try JSONSerialization.jsonObject(with: catalogData) as! [String: Any]
var iosFiles = Set<String>()
for entry in catalog["images"] as! [[String: String]] {
    guard let filename = entry["filename"], iosFiles.insert(filename).inserted else { continue }
    let points = Double(entry["size"]!.components(separatedBy: "x")[0])!
    let scale = Double(entry["scale"]!.dropLast())!
    let size = Int(points * scale)
    let context = canvas(size, size, opaque: true)
    background(context, CGRect(x: 0, y: 0, width: size, height: size))
    symbol(context, center: CGPoint(x: size / 2, y: size / 2), width: CGFloat(size) * 0.68)
    try save(context, "\(iosDirectory)/\(filename)")
}

// Windows ICO stores PNG images at each common shell size, including high DPI.
func appendLE(_ value: Int, bytes: Int, to data: inout Data) {
    for shift in 0..<bytes { data.append(UInt8((value >> (shift * 8)) & 0xff)) }
}
let windowsSizes = [16, 24, 32, 48, 64, 128, 256]
var windowsImages = [Data]()
for size in windowsSizes {
    let context = canvas(size, size)
    tile(context, size: CGFloat(size), inset: CGFloat(size) * 0.05, shadow: false)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    windowsImages.append(data as Data)
}
var ico = Data()
appendLE(0, bytes: 2, to: &ico)
appendLE(1, bytes: 2, to: &ico)
appendLE(windowsSizes.count, bytes: 2, to: &ico)
var offset = 6 + windowsSizes.count * 16
for (size, data) in zip(windowsSizes, windowsImages) {
    ico.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0])
    appendLE(1, bytes: 2, to: &ico)
    appendLE(32, bytes: 2, to: &ico)
    appendLE(data.count, bytes: 4, to: &ico)
    appendLE(offset, bytes: 4, to: &ico)
    offset += data.count
}
for data in windowsImages { ico.append(data) }
try ico.write(to: root.appendingPathComponent("windows/runner/resources/app_icon.ico"))

let linuxIcon = canvas(512, 512)
tile(linuxIcon, size: 512, inset: 512 * 0.05, shadow: false)
try save(linuxIcon, "linux/icons/tech.soit.flutterairplay.png")

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let context = canvas(size, size)
    tile(context, size: CGFloat(size), inset: CGFloat(size) * 0.09375, shadow: true)
    try save(context, "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_\(size).png")
}

for (density, scale) in [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0), ("xxhdpi", 3.0), ("xxxhdpi", 4.0)] {
    let legacySize = Int(48 * scale)
    let legacy = canvas(legacySize, legacySize)
    tile(legacy, size: CGFloat(legacySize), inset: CGFloat(legacySize) * 0.05, shadow: false)
    try save(legacy, "android/app/src/main/res/mipmap-\(density)/ic_launcher.png")

    // Adaptive layers are 108 dp; the symbol stays inside the central 66 dp safe area.
    let adaptiveSize = Int(108 * scale)
    let foreground = canvas(adaptiveSize, adaptiveSize)
    symbol(foreground, center: CGPoint(x: adaptiveSize / 2, y: adaptiveSize / 2), width: 54 * scale)
    try save(foreground, "android/app/src/main/res/mipmap-\(density)/ic_launcher_foreground.png")
    foreground.setBlendMode(.sourceIn)
    foreground.setFillColor(NSColor.white.cgColor)
    foreground.fill(CGRect(x: 0, y: 0, width: adaptiveSize, height: adaptiveSize))
    try save(foreground, "android/app/src/main/res/mipmap-\(density)/ic_launcher_monochrome.png")
}

// Android TV uses a banner as its launcher entry on many devices.
let banner = canvas(320, 180)
background(banner, CGRect(x: 0, y: 0, width: 320, height: 180))
symbol(banner, center: CGPoint(x: 160, y: 112), width: 90)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: banner, flipped: false)
let title = "Flutter AirPlay" as NSString
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: NSColor.white,
]
let titleSize = title.size(withAttributes: attributes)
title.draw(at: CGPoint(x: (320 - titleSize.width) / 2, y: 35), withAttributes: attributes)
NSGraphicsContext.restoreGraphicsState()
try save(banner, "android/app/src/main/res/drawable-xhdpi/tv_banner.png")

print("Generated Android, macOS, Windows, Linux, iPhone/iPad icons and the TV banner.")
