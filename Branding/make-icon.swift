// The CueVideo app icon, drawn the way the Cue family's icons are (CueScreens' Tools/make_icons.swift):
// a 648 point artwork tile (y down) on the midnight tile, the three Signal blues, bars round on the left
// and cut on the brand slant on the right. The camera body is CueScreens' screen frame, with cue bars
// inside, a lens to the right and a handle on top. Shapes, not pixels, so it is sharp at every size.
// Usage: swift Branding/make-icon.swift     (writes Branding/cuevideo-icon-1024.png and Resources/AppIcon.icns)
import AppKit

let midnight = NSColor(srgbRed: 0x09/255, green: 0x10/255, blue: 0x18/255, alpha: 1)
let edge = NSColor(srgbRed: 0x4B/255, green: 0x50/255, blue: 0x55/255, alpha: 1)
let light = NSColor(srgbRed: 0xDA/255, green: 0xED/255, blue: 0xFA/255, alpha: 1)
let mid = NSColor(srgbRed: 0x5C/255, green: 0xA2/255, blue: 0xD9/255, alpha: 1)
let dark = NSColor(srgbRed: 0x2F/255, green: 0x5F/255, blue: 0x87/255, alpha: 1)

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = size / 1024
    // Artwork tile 12...636 maps to the macOS icon tile 100...924 (of 1024).
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (100 + (x - 12) * 824 / 624) * k, y: (1024 - (100 + (y - 12) * 824 / 624)) * k) }
    func L(_ v: CGFloat) -> CGFloat { v * 824 / 624 * k }
    // A cue bar: round on the left, cut on the brand's slant on the right.
    func bar(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ c: NSColor) {
        let h = y1 - y0, slant = h * 0.2, r = h / 2
        let p = NSBezierPath()
        p.move(to: P(x0 + r, y0)); p.line(to: P(x1, y0)); p.line(to: P(x1 - slant, y1)); p.line(to: P(x0 + r, y1))
        p.appendArc(withCenter: P(x0 + r, y0 + r), radius: L(r), startAngle: 270, endAngle: 90, clockwise: true)
        p.close(); c.setFill(); p.fill()
    }
    // CueScreens' screen frame: rounded on the left, slanted on the right.
    func frame(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ r: CGFloat) -> NSBezierPath {
        let slant = (y1 - y0) * 0.124
        let p = NSBezierPath()
        p.move(to: P(x0 + r, y0)); p.line(to: P(x1, y0)); p.line(to: P(x1 - slant, y1)); p.line(to: P(x0 + r, y1))
        p.appendArc(withCenter: P(x0 + r, y1 - r), radius: L(r), startAngle: 270, endAngle: 180, clockwise: true)
        p.line(to: P(x0, y0 + r))
        p.appendArc(withCenter: P(x0 + r, y0 + r), radius: L(r), startAngle: 180, endAngle: 90, clockwise: true)
        p.close(); return p
    }
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k), xRadius: 180 * k, yRadius: 180 * k)
    midnight.setFill(); tile.fill()
    edge.setStroke(); tile.lineWidth = max(1, 5 * k); tile.stroke()

    // Handle on top.
    let h = P(150, 180)
    light.setFill(); NSBezierPath(roundedRect: NSRect(x: h.x, y: h.y, width: L(120), height: L(34)), xRadius: L(17), yRadius: L(17)).fill()
    // The body: the screen frame, with two cue bars inside.
    light.setFill(); frame(104, 200, 430, 500, 46).fill()
    midnight.setFill(); frame(126, 221, 404, 478, 28).fill()
    bar(166, 276, 360, 336, mid)
    bar(166, 360, 310, 420, dark)
    // The lens, opening to the right.
    let lens = NSBezierPath()
    lens.move(to: P(446, 314)); lens.line(to: P(548, 250)); lens.line(to: P(548, 450)); lens.line(to: P(430, 386)); lens.close()
    light.setFill(); lens.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try! draw(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Branding/cuevideo-icon-1024.png"))
let set = FileManager.default.temporaryDirectory.appendingPathComponent("CueVideo.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try! draw(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent("icon_\(name).png"))
}
let p = Process(); p.launchPath = "/usr/bin/iconutil"
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
p.launch(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("wrote Resources/AppIcon.icns and Branding/cuevideo-icon-1024.png")
