import AppKit
import CoreGraphics

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func renderIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let s = CGFloat(size)
    let margin = s * 0.095
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let radius = rect.width * 0.225

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.02),
        blur: s * 0.045,
        color: NSColor(calibratedWhite: 0, alpha: 0.38).cgColor
    )
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bgPath)
    ctx.setFillColor(NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.22, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle for gradient & artwork
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradColors = [
        NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.22, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.09, green: 0.22, blue: 0.48, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.05, green: 0.48, blue: 0.72, alpha: 1.0).cgColor
    ] as CFArray
    let locations: [CGFloat] = [0.0, 0.55, 1.0]
    let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: locations)!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.minY),
        end: CGPoint(x: rect.maxX, y: rect.maxY),
        options: []
    )

    // Top-right radial glow
    let glowColors = [
        NSColor(calibratedRed: 0.25, green: 0.85, blue: 1.0, alpha: 0.35).cgColor,
        NSColor(calibratedRed: 0.25, green: 0.85, blue: 1.0, alpha: 0.0).cgColor
    ] as CFArray
    let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.maxY - rect.height * 0.20),
        startRadius: 0,
        endCenter: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.maxY - rect.height * 0.20),
        endRadius: rect.width * 0.65,
        options: []
    )

    // Draw SF Symbol ("network.badge.shield.half.filled") centered in squircle
    let symbolPointSize = rect.width * 0.54
    let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        .applying(.init(paletteColors: [
            NSColor.white,
            NSColor(calibratedRed: 0.38, green: 0.92, blue: 1.0, alpha: 1.0)
        ]))
    if let sym = NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symSize = sym.size
        let drawRect = CGRect(
            x: rect.midX - symSize.width / 2 + s * 0.015,
            y: rect.midY - symSize.height / 2 - s * 0.01,
            width: symSize.width,
            height: symSize.height
        )
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.012),
            blur: s * 0.03,
            color: NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.14, alpha: 0.55).cgColor
        )
        sym.draw(in: drawRect)
        ctx.restoreGState()
    }

    // Inner glass border highlight
    ctx.addPath(bgPath)
    ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.22).cgColor)
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.strokePath()

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tmpDir = NSTemporaryDirectory() + "DNSSwitcher-\(ProcessInfo.processInfo.globallyUniqueString)"
let iconsetPath = "\(tmpDir)/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: tmpDir) }

for item in sizes {
    let rep = renderIcon(size: item.pixels)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(item.name)"))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetPath, "-o", outputPath]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}
