// Draws the MacDub app icon with Core Graphics and writes Packaging/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (needs only the Command Line Tools)
//
// Design: macOS rounded square, deep indigo gradient, a white speech bubble carrying a
// pink→orange waveform — "voice, translated".
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("Packaging/AppIcon.icns")

func render(px: Int) -> CGImage {
    let size = CGFloat(px)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: the squircle occupies ~82 % of the canvas.
    let inset = size * 0.09
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

    // Drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.035,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.30, green: 0.18, blue: 0.62, alpha: 1),
        CGColor(red: 0.11, green: 0.08, blue: 0.30, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    // Soft highlight in the top-left corner.
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.minX + tile.width * 0.25, y: tile.maxY - tile.height * 0.2),
                           startRadius: 0, endCenter: CGPoint(x: tile.minX + tile.width * 0.25, y: tile.maxY - tile.height * 0.2),
                           endRadius: tile.width * 0.8, options: [])
    ctx.restoreGState()

    // Speech bubble.
    let bubble = CGRect(x: tile.minX + tile.width * 0.17, y: tile.minY + tile.height * 0.34,
                        width: tile.width * 0.66, height: tile.height * 0.44)
    let bubblePath = CGMutablePath()
    bubblePath.addRoundedRect(in: bubble, cornerWidth: bubble.height * 0.28, cornerHeight: bubble.height * 0.28)
    // Tail bottom-left.
    let tailBase = CGPoint(x: bubble.minX + bubble.width * 0.22, y: bubble.minY + bubble.height * 0.02)
    bubblePath.move(to: tailBase)
    bubblePath.addLine(to: CGPoint(x: tailBase.x - bubble.width * 0.05, y: bubble.minY - bubble.height * 0.20))
    bubblePath.addLine(to: CGPoint(x: tailBase.x + bubble.width * 0.16, y: tailBase.y))
    bubblePath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.008), blur: size * 0.02, color: CGColor(gray: 0, alpha: 0.30))
    ctx.addPath(bubblePath)
    ctx.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Waveform bars inside the bubble, pink → orange.
    let heights: [CGFloat] = [0.32, 0.62, 1.0, 0.72, 0.42, 0.24]
    let barArea = bubble.insetBy(dx: bubble.width * 0.14, dy: bubble.height * 0.20)
    let gap = barArea.width * 0.06
    let barW = (barArea.width - gap * CGFloat(heights.count - 1)) / CGFloat(heights.count)
    let wave = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1.00, green: 0.32, blue: 0.55, alpha: 1),
        CGColor(red: 1.00, green: 0.55, blue: 0.25, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let x = barArea.minX + CGFloat(i) * (barW + gap)
        let bh = barArea.height * h
        let r = CGRect(x: x, y: barArea.midY - bh / 2, width: barW, height: bh)
        bars.addRoundedRect(in: r, cornerWidth: barW / 2, cornerHeight: barW / 2)
    }
    ctx.addPath(bars)
    ctx.clip()
    ctx.drawLinearGradient(wave, start: CGPoint(x: barArea.minX, y: 0), end: CGPoint(x: barArea.maxX, y: 0), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: url)
}

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try writePNG(render(px: px), to: iconset.appendingPathComponent("\(name).png"))
}
// A loose 512 px preview next to the icns, handy for the README and the in-app views.
try writePNG(render(px: 512), to: root.appendingPathComponent("Packaging/AppIcon-512.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("✔ \(output.path)")
