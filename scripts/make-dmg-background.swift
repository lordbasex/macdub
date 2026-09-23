// Draws the background of the installer disk image and writes Packaging/dmg-background.tiff
// (a multi-resolution TIFF: 1× and 2× so it is crisp on Retina Finder windows).
// Usage: swift scripts/make-dmg-background.swift   (needs only the Command Line Tools)
//
// Layout (in points, must match scripts/make-dmg.sh): 660×400 window, MacDub.app at (165, 190),
// Applications at (495, 190), an arrow between them and one line of text underneath.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let buildDir = root.appendingPathComponent("build")
let output = root.appendingPathComponent("Packaging/dmg-background.tiff")
let width = 660.0, height = 400.0

func render(scale: CGFloat) -> CGImage {
    let px = Int(width * scale), py = Int(height * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)

    // The amber gradient of the History screen (Theme.amber): top-left → bottom-right, with the
    // same soft white highlight MainView paints at (35 %, 25 %).
    let colors = [CGColor(red: 0.80, green: 0.30, blue: 0.08, alpha: 1), CGColor(red: 0.26, green: 0.07, blue: 0.04, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
    let highlight = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.12), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    let hc = CGPoint(x: width * 0.35, y: height * 0.75)
    ctx.drawRadialGradient(highlight, startCenter: hc, startRadius: 0, endCenter: hc, endRadius: 340, options: [])

    // Soft glow behind the icons.
    for cx in [165.0, 495.0] {
        let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.10), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: height - 190), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: height - 190), endRadius: 110, options: [])
    }

    // Arrow from the app to Applications: white, it has to read over the orange.
    let y = height - 190
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 258, y: y))
    arrow.addLine(to: CGPoint(x: 392, y: y))
    arrow.move(to: CGPoint(x: 370, y: y + 18))
    arrow.addLine(to: CGPoint(x: 396, y: y))
    arrow.addLine(to: CGPoint(x: 370, y: y - 18))
    ctx.addPath(arrow)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    ctx.strokePath()

    // Text.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: style]
        NSAttributedString(string: text, attributes: attrs).draw(in: CGRect(x: 0, y: y, width: width, height: size * 1.4))
    }
    draw("Drag MacDub to your Applications folder", size: 15, weight: .medium, alpha: 0.92, y: 62)
    draw("Real-time, fully offline dubbing for macOS", size: 12, weight: .regular, alpha: 0.6, y: 40)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
var pngs: [URL] = []
for scale in [1.0, 2.0] as [CGFloat] {
    let url = buildDir.appendingPathComponent(scale == 1 ? "dmg-background.png" : "dmg-background@2x.png")
    let rep = NSBitmapImageRep(cgImage: render(scale: scale))
    rep.size = NSSize(width: width, height: height) // points, so the DPI tags the scale
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    pngs.append(url)
}
// tiffutil folds both scales into one TIFF Finder picks the right one from.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
task.arguments = ["-cathidpicheck", pngs[0].path, pngs[1].path, "-out", output.path]
try! task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "✔ \(output.path)" : "✘ tiffutil failed")
