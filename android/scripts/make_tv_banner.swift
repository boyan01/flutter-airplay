// SPDX-License-Identifier: GPL-3.0-only
// Rebuild the 320 x 180 xhdpi launcher banner on macOS with Apple's system fonts.
// swift -module-cache-path /tmp/airplay-swift-cache android/scripts/make_tv_banner.swift
import AppKit
import CoreText
import ImageIO

let output = URL(fileURLWithPath: "android/app/src/main/res/drawable-xhdpi/tv_banner.png")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.04, green: 0.08, blue: 0.14, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
context.setStrokeColor(CGColor(red: 0.55, green: 0.78, blue: 1, alpha: 1))
context.setLineWidth(4)
context.stroke(CGRect(x: 132, y: 104, width: 56, height: 36))
context.setFillColor(CGColor(red: 0.55, green: 0.78, blue: 1, alpha: 1))
context.move(to: CGPoint(x: 160, y: 121))
context.addLine(to: CGPoint(x: 174, y: 98))
context.addLine(to: CGPoint(x: 146, y: 98))
context.closePath()
context.fillPath()
let title = NSAttributedString(string: "Flutter AirPlay", attributes: [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.white,
])
let line = CTLineCreateWithAttributedString(title)
context.textPosition = CGPoint(x: (320 - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: 52)
CTLineDraw(line, context)
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
assert(CGImageDestinationFinalize(destination))
