import AppKit
import CoreGraphics
import Foundation

// MARK: - Arguments & Configuration
let args = CommandLine.arguments
let appPath = args.count > 1 ? args[1] : "DNSSwitcher.app"
let outputDmg = args.count > 2 ? args[2] : "DNSSwitcher.dmg"
let volName = args.count > 3 ? args[3] : "AI DNS Switcher"

let fileManager = FileManager.default

guard fileManager.fileExists(atPath: appPath) else {
    fputs("❌ Ошибка: приложение не найдено по пути: \(appPath)\n", stderr)
    exit(1)
}

print("📦 Сборка фирменного DMG-образа...")
print("   • Приложение: \(appPath)")
print("   • Выходной файл: \(outputDmg)")
print("   • Том: \(volName)")

// MARK: - Helper: Run shell command
@discardableResult
func run(_ command: String, arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    } catch {
        return (-1, "\(error)")
    }
}

// MARK: - 1. Render High-Resolution Retina Background
let width: CGFloat = 600
let height: CGFloat = 380
let scale: CGFloat = 2.0
let pxW = Int(width * scale)
let pxH = Int(height * scale)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pxW,
    pixelsHigh: pxH,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("❌ Ошибка: не удалось создать графический контекст\n", stderr)
    exit(1)
}

// Background dark-blue gradient
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bgColors = [
    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.14, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.22, alpha: 1.0).cgColor
] as CFArray
if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
}

func toCocoaY(_ finderY: CGFloat) -> CGFloat {
    return height - finderY
}

// Glow targets under App (x=150, y=185) and Applications (x=450, y=185)
let leftCenter = CGPoint(x: 150, y: toCocoaY(185))
let rightCenter = CGPoint(x: 450, y: toCocoaY(185))

func drawTargetGlow(at center: CGPoint, color: NSColor) {
    let glowColors = [
        color.withAlphaComponent(0.20).cgColor,
        color.withAlphaComponent(0.0).cgColor
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: 95, options: [])
    }
}

drawTargetGlow(at: leftCenter, color: NSColor(calibratedRed: 0.18, green: 0.55, blue: 1.0, alpha: 1.0))
drawTargetGlow(at: rightCenter, color: NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.95, alpha: 1.0))

// Sleek connecting neon gradient arrow in center
let arrowMidY = toCocoaY(185)
let arrowStart = CGPoint(x: 235, y: arrowMidY)
let arrowEnd = CGPoint(x: 365, y: arrowMidY)

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 14, color: NSColor(calibratedRed: 0.25, green: 0.65, blue: 1.0, alpha: 0.55).cgColor)
ctx.setStrokeColor(NSColor(calibratedRed: 0.40, green: 0.75, blue: 1.0, alpha: 0.65).cgColor)
ctx.setLineWidth(3.5)
ctx.setLineCap(.round)

let arrowPath = CGMutablePath()
arrowPath.move(to: arrowStart)
arrowPath.addLine(to: arrowEnd)
ctx.addPath(arrowPath)
ctx.strokePath()

let headPath = CGMutablePath()
headPath.move(to: CGPoint(x: arrowEnd.x - 14, y: arrowEnd.y + 10))
headPath.addLine(to: arrowEnd)
headPath.addLine(to: CGPoint(x: arrowEnd.x - 14, y: arrowEnd.y - 10))
ctx.setLineJoin(.round)
ctx.addPath(headPath)
ctx.strokePath()
ctx.restoreGState()

// Header Title & Subtitle
let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
let titleShadow = NSShadow()
titleShadow.shadowBlurRadius = 8
titleShadow.shadowOffset = NSSize(width: 0, height: -2)
titleShadow.shadowColor = NSColor.black.withAlphaComponent(0.65)

let titleStr = NSAttributedString(string: "AI DNS Switcher", attributes: [
    .font: titleFont,
    .foregroundColor: NSColor.white,
    .shadow: titleShadow
])
let titleSize = titleStr.size()
titleStr.draw(at: CGPoint(x: (width - titleSize.width) / 2.0, y: toCocoaY(48)))

let subFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
let subStr = NSAttributedString(string: "Безопасный DoH • Быстрое переключение DNS", attributes: [
    .font: subFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.55)
])
let subSize = subStr.size()
subStr.draw(at: CGPoint(x: (width - subSize.width) / 2.0, y: toCocoaY(74)))

// Bottom instruction pill badge
let bannerText = "Перетащите AI DNS Switcher в папку Программы"
let bannerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
let bannerStr = NSAttributedString(string: bannerText, attributes: [
    .font: bannerFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.85)
])
let bannerSize = bannerStr.size()

let pillPadH: CGFloat = 18
let pillPadV: CGFloat = 7
let pillRect = CGRect(
    x: (width - (bannerSize.width + pillPadH * 2)) / 2.0,
    y: toCocoaY(342) - pillPadV,
    width: bannerSize.width + pillPadH * 2,
    height: bannerSize.height + pillPadV * 2
)
let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillRect.height / 2.0, cornerHeight: pillRect.height / 2.0, transform: nil)
ctx.saveGState()
ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor)
ctx.addPath(pillPath)
ctx.fillPath()
ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor)
ctx.setLineWidth(1.0)
ctx.addPath(pillPath)
ctx.strokePath()
ctx.restoreGState()

bannerStr.draw(at: CGPoint(x: pillRect.origin.x + pillPadH, y: pillRect.origin.y + pillPadV))

NSGraphicsContext.restoreGraphicsState()

guard let bgData = rep.representation(using: .png, properties: [:]) else {
    fputs("❌ Ошибка: не удалось сгенерировать PNG фона\n", stderr)
    exit(1)
}

// MARK: - 2. Prepare Temporary Disk Image
let tempDmgPath = NSTemporaryDirectory() + "DNSSwitcher_temp_\(UUID().uuidString).dmg"
defer {
    try? fileManager.removeItem(atPath: tempDmgPath)
}

// Eject any stale volume with same name
_ = run("/usr/bin/hdiutil", arguments: ["detach", "/Volumes/\(volName)", "-force"])

print("💿 Создание промежуточного HFS+ образа...")
let createRes = run("/usr/bin/hdiutil", arguments: [
    "create",
    "-size", "140m",
    "-fs", "HFS+",
    "-volname", volName,
    "-ov",
    tempDmgPath
])
guard createRes.status == 0 else {
    fputs("❌ Ошибка при создании образа: \(createRes.output)\n", stderr)
    exit(1)
}

print("🔗 Монтирование образа...")
let attachRes = run("/usr/bin/hdiutil", arguments: [
    "attach",
    "-nobrowse",
    "-noverify",
    "-noautoopen",
    tempDmgPath
])
guard attachRes.status == 0 else {
    fputs("❌ Ошибка при монтировании: \(attachRes.output)\n", stderr)
    exit(1)
}

let mountPoint = "/Volumes/\(volName)"
guard fileManager.fileExists(atPath: mountPoint) else {
    fputs("❌ Ошибка: точка монтирования \(mountPoint) не существует\n", stderr)
    exit(1)
}

func detachVolume() {
    _ = run("/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-force"])
}

// MARK: - 3. Populate Volume Contents
print("📂 Копирование файлов в образ...")
let appDest = "\(mountPoint)/\(URL(fileURLWithPath: appPath).lastPathComponent)"
_ = run("/bin/cp", arguments: ["-R", appPath, appDest])

// Copy AppIcon as volume icon
let appIconSource = "\(appPath)/Contents/Resources/AppIcon.icns"
let volIconDest = "\(mountPoint)/.VolumeIcon.icns"
if fileManager.fileExists(atPath: appIconSource) {
    _ = run("/bin/cp", arguments: [appIconSource, volIconDest])
    _ = run("/usr/bin/SetFile", arguments: ["-a", "C", mountPoint])
    _ = run("/usr/bin/SetFile", arguments: ["-a", "V", volIconDest])
}

// Save background image
let bgDir = "\(mountPoint)/.background"
try? fileManager.createDirectory(atPath: bgDir, withIntermediateDirectories: true)
try? bgData.write(to: URL(fileURLWithPath: "\(bgDir)/background.png"))
_ = run("/usr/bin/SetFile", arguments: ["-a", "V", bgDir])

// MARK: - 4. Create Applications Finder Alias with Native Icon
print("📁 Создание нативного ярлыка Applications...")
let aliasScript = """
tell application "Finder"
    make new alias file at POSIX file "\(mountPoint)" to POSIX file "/Applications" with properties {name:"Applications"}
end tell
"""
var aliasErr: NSDictionary?
NSAppleScript(source: aliasScript)?.executeAndReturnError(&aliasErr)

// If AppleScript succeeded or fallback to symlink
let appsPath = "\(mountPoint)/Applications"
if !fileManager.fileExists(atPath: appsPath) {
    try? fileManager.createSymbolicLink(atPath: appsPath, withDestinationPath: "/Applications")
}

// Apply the native Applications folder icon directly to the alias file
let systemAppIconPath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
if let folderImg = NSImage(contentsOfFile: systemAppIconPath) {
    _ = NSWorkspace.shared.setIcon(folderImg, forFile: appsPath, options: [])
}

// MARK: - 5. Configure Finder Window & Layout
print("🎨 Настройка отображения окна и расположения иконок в Finder...")
let layoutScript = """
tell application "Finder"
    tell disk "\(volName)"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 200, 1000, 580}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 104
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "\(URL(fileURLWithPath: appPath).lastPathComponent)" of container window to {150, 185}
        set position of item "Applications" of container window to {450, 185}
        update without registering applications
        delay 1
        close
    end tell
end tell
"""
var layoutErr: NSDictionary?
NSAppleScript(source: layoutScript)?.executeAndReturnError(&layoutErr)
if let err = layoutErr {
    print("⚠️ Предупреждение AppleScript Finder: \(err)")
}

// Clean system files
_ = run("/usr/bin/SetFile", arguments: ["-a", "V", "\(mountPoint)/.fseventsd"])

// Sync disk before detach
sync()
sleep(1)
detachVolume()

// MARK: - 6. Convert to Final Compressed Read-Only DMG (UDZO)
print("🗜️ Сжатие в финальный DMG (UDZO zlib-9)...")
try? fileManager.removeItem(atPath: outputDmg)
let convertRes = run("/usr/bin/hdiutil", arguments: [
    "convert",
    tempDmgPath,
    "-format", "UDZO",
    "-imagekey", "zlib-level=9",
    "-o", outputDmg,
    "-ov"
])

guard convertRes.status == 0 else {
    fputs("❌ Ошибка конвертации DMG: \(convertRes.output)\n", stderr)
    exit(1)
}

print("✅ Фирменный образ успешно создан: \(outputDmg)")
