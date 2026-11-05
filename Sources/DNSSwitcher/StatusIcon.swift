import AppKit

public enum StatusIcon {
    private static var cache: [String: NSImage] = [:]

    public static func image(isActive: Bool, size: CGFloat = 18) -> NSImage {
        let key = "\(isActive)_\(size)"
        if let cached = cache[key] {
            return cached
        }
        let generated = createIcon(isActive: isActive, size: size)
        cache[key] = generated
        return generated
    }

    private static func createIcon(isActive: Bool, size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            // When active: network with DoH shield (network.badge.shield.half.filled)
            // When inactive: basic network symbol with clean slash and subtle opacity
            let symbolName = isActive ? "network.badge.shield.half.filled" : "network"
            let drawColor = isActive ? NSColor.black : NSColor.black.withAlphaComponent(0.40)

            if let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let pointSize = size * (15.0 / 18.0)
                let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                    .applying(.init(paletteColors: [drawColor]))
                let sym = base.withSymbolConfiguration(config) ?? base

                let rect = CGRect(
                    x: (size - sym.size.width) / 2.0,
                    y: (size - sym.size.height) / 2.0,
                    width: sym.size.width,
                    height: sym.size.height
                )
                sym.draw(in: rect)
            } else {
                let r = (size - 3.0) / 2.0
                let center = CGPoint(x: size / 2.0, y: size / 2.0)
                let globeRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                ctx.setLineWidth(1.2)
                ctx.setStrokeColor(drawColor.cgColor)
                ctx.strokeEllipse(in: globeRect)
            }

            if !isActive {
                // Subtle clean diagonal strike
                let pad = size * 0.08
                ctx.setStrokeColor(drawColor.cgColor)
                ctx.setLineWidth(max(1.15, size * 0.065))
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: pad, y: size - pad))
                ctx.addLine(to: CGPoint(x: size - pad, y: pad))
                ctx.strokePath()
            }

            return true
        }
        img.isTemplate = true
        return img
    }

    public static func appIconImage(size: CGFloat = 256) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size),
            pixelsHigh: Int(size),
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
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            return NSImage(size: NSSize(width: size, height: size))
        }

        let s = size
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
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: locations) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        }

        // Top-right radial glow
        let glowColors = [
            NSColor(calibratedRed: 0.25, green: 0.85, blue: 1.0, alpha: 0.35).cgColor,
            NSColor(calibratedRed: 0.25, green: 0.85, blue: 1.0, alpha: 0.0).cgColor
        ] as CFArray
        if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
            ctx.drawRadialGradient(
                glowGrad,
                startCenter: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.maxY - rect.height * 0.20),
                startRadius: 0,
                endCenter: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.maxY - rect.height * 0.20),
                endRadius: rect.width * 0.65,
                options: []
            )
        }

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

        let finalImage = NSImage(size: NSSize(width: size, height: size))
        finalImage.addRepresentation(rep)
        return finalImage
    }
}
