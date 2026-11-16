// Renders the official app icons installed on this Mac into the asset catalog,
// so the dock can show the real Apple Music / Maps / Phone / Messages icons.
// The images are Apple's (and Spotify's) artwork, included in the repo; run this to
// refresh them from the apps on your Mac (e.g. after a macOS redesign):
//   swift scripts/extract-app-icons.swift
import AppKit

let apps: [(asset: String, paths: [String])] = [
    ("AppIconMaps", ["/System/Applications/Maps.app"]),
    ("AppIconMusic", ["/System/Applications/Music.app"]),
    ("AppIconPhone", ["/System/Applications/Phone.app", "/System/Applications/FaceTime.app"]),
    ("AppIconMessages", ["/System/Applications/Messages.app"]),
    ("AppIconSpotify", ["/Applications/Spotify.app"]),
    ("AppIconSettings", ["/System/Applications/System Settings.app"]),
]

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DuoDash/Assets.xcassets")
let side = 360  // px; tiles are at most ~66 pt @3x = 198 px
// macOS icons sit on a 1024 grid with a 100 px margin; crop to the squircle itself.
let inset = 100.0 / 1024.0

for app in apps {
    guard let path = app.paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        print("skip \(app.asset): not installed"); continue
    }
    let icon = NSWorkspace.shared.icon(forFile: path)
    let full = CGFloat(side) / (1 - 2 * inset)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let origin = -full * inset
    // Draw as the standard light (Aqua) full-colour icon, whatever icon style
    // (tinted / clear / dark) this Mac is set to.
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        icon.draw(in: NSRect(x: origin, y: origin, width: full, height: full),
                  from: .zero, operation: .copy, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }

    let set = root.appendingPathComponent("\(app.asset).imageset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try png.write(to: set.appendingPathComponent("icon.png"))
    let contents = """
    {"images":[{"filename":"icon.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}
    """
    try contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("wrote \(app.asset) from \(path)")
}
