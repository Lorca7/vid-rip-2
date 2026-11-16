// Draws VidRip's app icon and writes an .iconset folder.
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.22, alpha: 1),
                        NSColor(calibratedRed: 0.86, green: 0.10, blue: 0.32, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Film strip
    let strip = NSRect(x: tile.minX, y: tile.midY - tile.height * 0.16, width: tile.width, height: tile.height * 0.32)
    NSColor(white: 0, alpha: 0.28).setFill()
    strip.fill()
    NSColor(white: 1, alpha: 0.9).setFill()
    let hole = tile.width * 0.05
    var x = tile.minX + hole
    while x < tile.maxX - hole {
        NSBezierPath(roundedRect: NSRect(x: x, y: strip.maxY - hole * 1.4, width: hole, height: hole * 0.8), xRadius: hole * 0.2, yRadius: hole * 0.2).fill()
        NSBezierPath(roundedRect: NSRect(x: x, y: strip.minY + hole * 0.6, width: hole, height: hole * 0.8), xRadius: hole * 0.2, yRadius: hole * 0.2).fill()
        x += hole * 2
    }

    // Selection window
    let window = NSRect(x: tile.minX + tile.width * 0.3, y: strip.minY - tile.height * 0.04,
                        width: tile.width * 0.4, height: strip.height + tile.height * 0.08)
    let frame = NSBezierPath(roundedRect: window, xRadius: size * 0.02, yRadius: size * 0.02)
    frame.lineWidth = size * 0.035
    NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1).setStroke()
    frame.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = drawIcon(size: CGFloat(base * scale))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
print("Wrote \(output.path)")
