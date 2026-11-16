// Choose the app's Home Screen name and icon for your own builds.
// The default (Config/Base.xcconfig) is "CarPlay" with the CarPlay logo.
//   swift scripts/local-branding.swift --duo-dash                      # "Duo Dash" name and icon
//   swift scripts/local-branding.swift --icon <image> ["My Name"]      # your own icon (and name)
//   swift scripts/local-branding.swift "My Name"                       # rename, keep the icon
//   swift scripts/local-branding.swift --reset                         # back to the default
// Writes only the name/icon lines of the git-ignored Config/Local.xcconfig (your signing
// settings there are kept). A custom icon goes to the git-ignored AppIconLocal.appiconset.
import AppKit

let fm = FileManager.default
let xcconfig = URL(fileURLWithPath: "Config/Local.xcconfig")
let iconSet = URL(fileURLWithPath: "DuoDash/Assets.xcassets/AppIconLocal.appiconset")
var args = Array(CommandLine.arguments.dropFirst())

/// Replace the branding lines in Local.xcconfig, keeping everything else.
func writeBranding(name: String?, icon: String?) throws {
    let existing = (try? String(contentsOf: xcconfig, encoding: .utf8)) ?? ""
    var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        .filter { !$0.hasPrefix("DUODASH_DISPLAY_NAME") && !$0.hasPrefix("DUODASH_APP_ICON") && !$0.hasPrefix("// Branding") }
    while lines.last == "" { lines.removeLast() }
    var add: [String] = []
    if let name { add.append("DUODASH_DISPLAY_NAME = \(name)") }
    if let icon { add.append("DUODASH_APP_ICON = \(icon)") }
    if !add.isEmpty { lines += ["", "// Branding (scripts/local-branding.swift). Git-ignored."] + add }
    try (lines.joined(separator: "\n") + "\n").write(to: xcconfig, atomically: true, encoding: .utf8)
}

if args.first == "--reset" {
    try writeBranding(name: nil, icon: nil)
    try? fm.removeItem(at: iconSet)
    print("Back to the default name and icon (CarPlay). Rebuild to apply.")
    exit(0)
}
if args.first == "--duo-dash" {
    try writeBranding(name: "Duo Dash", icon: "AppIcon")
    print("App name: Duo Dash; icon: Duo Dash. Rebuild to apply.")
    exit(0)
}

var iconSource: NSImage?
if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
    let path = (args[i + 1] as NSString).expandingTildeInPath
    guard let image = NSImage(contentsOfFile: path) else { print("Can't read image at \(path)"); exit(1) }
    iconSource = image
    args.removeSubrange(i...(i + 1))
}
let name = args.first

if let iconSource {
    // 1024×1024, a touch enlarged so an image's own rounded corners never show once iOS masks it.
    let side = 1024
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    let grow = CGFloat(side) * 0.06
    iconSource.draw(in: rect.insetBy(dx: -grow, dy: -grow), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try fm.createDirectory(at: iconSet, withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: iconSet.appendingPathComponent("AppIcon.png"))
    try """
    {"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
    """.write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
try writeBranding(name: name, icon: iconSource == nil ? nil : "AppIconLocal")
print("Name: \(name ?? "(unchanged)"); icon: \(iconSource == nil ? "(unchanged)" : "custom"). Rebuild to apply.")
