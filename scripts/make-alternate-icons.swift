#!/usr/bin/env swift
// Draws Duo Dash's alternate app icons (Duo Dash Pro → App icon) from the same gauge glyph as
// DuoDash/Assets.xcassets/AppIcon.appiconset, in a few colourways. Writes, for each variant:
//   DuoDash/Assets.xcassets/<Name>.appiconset/<Name>.png         (1024 px, opaque, the real icon)
//   DuoDash/Assets.xcassets/<Name>Preview.imageset/preview.png   (180 px, shown in Settings)
// plus AppIconPreview.imageset for the default icon. Re-run after changing a colourway:
//   swift scripts/make-alternate-icons.swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGB { var r, g, b: CGFloat; var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) } }
func hex(_ v: UInt32) -> RGB { RGB(r: CGFloat((v >> 16) & 0xFF) / 255, g: CGFloat((v >> 8) & 0xFF) / 255, b: CGFloat(v & 0xFF) / 255) }

struct Variant {
    let name: String
    /// Background: top-left to bottom-right gradient.
    let background: [RGB]
    /// The lit part of the gauge and the right-hand bar.
    let accent: RGB
    /// The unlit track and the left bar.
    let track: RGB
    /// Needle and hub.
    let needle: RGB
}

let variants: [Variant] = [
    // The default icon, redrawn only for its Settings preview.
    Variant(name: "AppIcon", background: [hex(0x0A0C0E), hex(0x0A0C0E)], accent: hex(0x3ECDA0), track: hex(0x282C35), needle: hex(0xFFFFFF)),
    Variant(name: "AppIconMidnight", background: [hex(0x0B1430), hex(0x03060F)], accent: hex(0x0A84FF), track: hex(0x1E2A4A), needle: hex(0xFFFFFF)),
    Variant(name: "AppIconSilver", background: [hex(0xF7F8FA), hex(0xD9DCE3)], accent: hex(0x0A84FF), track: hex(0xC3C8D2), needle: hex(0x1C1C1E)),
    Variant(name: "AppIconOcean", background: [hex(0x2A8CFF), hex(0x1338B8)], accent: hex(0xFFFFFF), track: hex(0x5E8FE6), needle: hex(0xFFFFFF)),
    Variant(name: "AppIconSunset", background: [hex(0xFF9F0A), hex(0xE83A6B)], accent: hex(0xFFFFFF), track: hex(0xF59A8C), needle: hex(0xFFFFFF)),
]

func draw(_ v: Variant, size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Work in the 1024 design space with y pointing down, like the original artwork.
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: v.background.map(\.cg) as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])

    let centre = CGPoint(x: 512, y: 552)
    let radius: CGFloat = 305
    let thickness: CGFloat = 70
    // Angles in the y-down space: 150° is lower left, 30° lower right, 300° (-60°) upper right.
    func rad(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }
    ctx.setLineWidth(thickness)
    ctx.setLineCap(.butt)
    // Unlit track: from the needle angle round to the lower right.
    ctx.setStrokeColor(v.track.cg)
    ctx.addArc(center: centre, radius: radius, startAngle: rad(-60), endAngle: rad(30), clockwise: false)
    ctx.strokePath()
    // Lit part: lower left round to the needle.
    ctx.setStrokeColor(v.accent.cg)
    ctx.addArc(center: centre, radius: radius, startAngle: rad(150), endAngle: rad(300), clockwise: false)
    ctx.strokePath()

    // Needle and hub.
    ctx.setStrokeColor(v.needle.cg)
    ctx.setLineWidth(26)
    ctx.move(to: centre)
    ctx.addLine(to: CGPoint(x: centre.x + cos(rad(-60)) * 300, y: centre.y + sin(rad(-60)) * 300))
    ctx.strokePath()
    ctx.setFillColor(v.needle.cg)
    ctx.fillEllipse(in: CGRect(x: centre.x - 57, y: centre.y - 57, width: 114, height: 114))

    // The two bars underneath.
    ctx.setFillColor(v.track.cg)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 292, y: 760, width: 208, height: 70), cornerWidth: 24, cornerHeight: 24, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(v.accent.cg)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 524, y: 760, width: 208, height: 70), cornerWidth: 24, cornerHeight: 24, transform: nil))
    ctx.fillPath()
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icons", code: 1) }
}

func writeJSON(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "DuoDash/Assets.xcassets")
for v in variants {
    if v.name != "AppIcon" {
        let set = root.appending(path: "\(v.name).appiconset")
        try write(draw(v, size: 1024), to: set.appending(path: "\(v.name).png"))
        try writeJSON("""
        {
          "images" : [
            {
              "filename" : "\(v.name).png",
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }

        """, to: set.appending(path: "Contents.json"))
    }
    let preview = root.appending(path: "\(v.name)Preview.imageset")
    try write(draw(v, size: 180), to: preview.appending(path: "preview.png"))
    try writeJSON("""
    {
      "images" : [
        { "filename" : "preview.png", "idiom" : "universal" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """, to: preview.appending(path: "Contents.json"))
    print("wrote \(v.name)")
}
