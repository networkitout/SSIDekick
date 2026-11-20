// Draws the WiFiUtil app icon and writes Support/AppIcon.icns.
// Run from the repo root:  swift scripts/make-icon.swift [output.icns]
//
// Everything is drawn here with Core Graphics (no SF Symbols: their license excludes app icons).
// Coordinates are on Apple's 1024 pt macOS icon grid: the body is an 824 pt rounded square inset
// 100 pt, so the icon lines up with system icons. y points up.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/AppIcon.icns"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The body: Apple's macOS icon grid shape, an 824 pt rounded square inset 100 pt with 185.4 pt corners.
/// Keep this exact shape: macOS 26 shows a legacy .icns edge to edge only when its outline matches the
/// system mask, and otherwise shrinks it onto a grey plate. (A superellipse got the plate.)
func bodyPath() -> CGPath {
    CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
           cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)
}

func shieldPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512, y: 846))
    p.addQuadCurve(to: CGPoint(x: 776, y: 790), control: CGPoint(x: 652, y: 842))
    p.addLine(to: CGPoint(x: 776, y: 560))
    p.addCurve(to: CGPoint(x: 512, y: 192), control1: CGPoint(x: 776, y: 356), control2: CGPoint(x: 644, y: 246))
    p.addCurve(to: CGPoint(x: 248, y: 560), control1: CGPoint(x: 380, y: 246), control2: CGPoint(x: 248, y: 356))
    p.addLine(to: CGPoint(x: 248, y: 790))
    p.addQuadCurve(to: CGPoint(x: 512, y: 846), control: CGPoint(x: 372, y: 842))
    p.closeSubpath()
    return p
}

func draw(in ctx: CGContext) {
    let body = bodyPath()

    // Soft drop shadow under the body, as on system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.30))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x0B3D91))
    ctx.fillPath()
    ctx.restoreGState()

    // Blue gradient fill, lighter at the top.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [rgb(0x3D8BFF), rgb(0x0A3A8C)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Translucent shield behind the Wi-Fi fan.
    let shield = shieldPath()
    ctx.addPath(shield)
    ctx.setFillColor(rgb(0xFFFFFF, 0.16))
    ctx.fillPath()
    ctx.addPath(shield)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.42))
    ctx.setLineWidth(12)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Wi-Fi fan: a dot and three arcs spanning 45° either side of vertical.
    let center = CGPoint(x: 512, y: 350)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x001A4D, 0.35))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(54)
    ctx.setLineCap(.round)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.fillEllipse(in: CGRect(x: center.x - 42, y: center.y - 42, width: 84, height: 84))
    for radius in [100.0, 180.0, 260.0] {
        ctx.addArc(center: center, radius: radius, startAngle: .pi / 4, endAngle: 3 * .pi / 4, clockwise: false)
        ctx.strokePath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("error: iconutil failed with status \(iconutil.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}
print(output)
