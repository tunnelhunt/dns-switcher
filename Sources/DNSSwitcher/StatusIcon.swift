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

            // 1. Draw base globe symbol (SF Symbol "globe") or vector fallback
            let symbolPt = size * (15.0 / 18.0)
            if let baseSymbol = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: symbolPt, weight: .regular)
                let configured = baseSymbol.withSymbolConfiguration(config) ?? baseSymbol
                let symbolRect = CGRect(
                    x: (size - configured.size.width) / 2.0,
                    y: (size - configured.size.height) / 2.0,
                    width: configured.size.width,
                    height: configured.size.height
                )
                configured.draw(in: symbolRect)
            } else {
                let r = (size - 3.0) / 2.0
                let center = CGPoint(x: size / 2.0, y: size / 2.0)
                let globeRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                ctx.setLineWidth(1.2)
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.addEllipse(in: globeRect)
                ctx.strokePath()

                let latOffset = r * 0.48
                let latHalfW = sqrt(max(0, r * r - latOffset * latOffset))
                let topLatRect = CGRect(x: center.x - latHalfW, y: center.y + latOffset - 1.5, width: latHalfW * 2, height: 3.0)
                ctx.addEllipse(in: topLatRect)
                ctx.strokePath()

                let btmLatRect = CGRect(x: center.x - latHalfW, y: center.y - latOffset - 1.5, width: latHalfW * 2, height: 3.0)
                ctx.addEllipse(in: btmLatRect)
                ctx.strokePath()

                let meridianW = r * 0.8
                let meridianRect = CGRect(x: center.x - meridianW / 2.0, y: center.y - r, width: meridianW, height: r * 2)
                ctx.addEllipse(in: meridianRect)
                ctx.strokePath()
            }

            // 2. Clear center equator band and draw bold "DNS"
            let fontSize = max(4.5, size * (5.5 / 18.0))
            let font = NSFont.systemFont(ofSize: fontSize, weight: .black)
            let attrStr = NSAttributedString(string: "DNS", attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
                .kern: -0.2
            ])
            let strSize = attrStr.size()
            let textRect = CGRect(
                x: (size - strSize.width) / 2.0,
                y: (size - strSize.height) / 2.0 - 0.2,
                width: strSize.width,
                height: strSize.height
            )

            // Knockout cutout so grid lines do not collide with "DNS"
            let knockoutRect = textRect.insetBy(dx: -1.0, dy: -0.4)
            ctx.setBlendMode(.clear)
            ctx.fill(knockoutRect)
            ctx.setBlendMode(.normal)

            attrStr.draw(at: textRect.origin)

            // 3. When disabled (inactive), draw diagonal strike-through slash (macOS Wi-Fi style)
            if !isActive {
                let pad: CGFloat = size * (1.6 / 18.0)
                let p1 = CGPoint(x: pad, y: size - pad)
                let p2 = CGPoint(x: size - pad, y: pad)

                // Knockout gap around slash
                ctx.setBlendMode(.clear)
                ctx.setLineWidth(size * (2.6 / 18.0))
                ctx.setLineCap(.round)
                ctx.move(to: p1)
                ctx.addLine(to: p2)
                ctx.strokePath()

                // Foreground slash line
                ctx.setBlendMode(.normal)
                ctx.setLineWidth(size * (1.35 / 18.0))
                ctx.setLineCap(.round)
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.move(to: p1)
                ctx.addLine(to: p2)
                ctx.strokePath()
            }

            return true
        }
        img.isTemplate = true
        return img
    }
}
