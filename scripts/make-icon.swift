// Draws the SSIDekick app icon (a magnifying glass over a blue Wi-Fi symbol) and writes Support/AppIcon.icns.
// Run from the repo root:  swift scripts/make-icon.swift [output.icns]
//
// Everything is drawn here with Core Graphics (no SF Symbols: their license excludes app icons).
// Coordinates are on Apple's 1024 pt macOS icon grid; y points up.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/AppIcon.icns"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The body: Apple's macOS icon grid shape, an 824 pt rounded square inset 100 pt with 185.4 pt corners.
/// Keep this exact shape: macOS 26 shows a legacy .icns edge to edge only when its outline matches the
/// system mask, and otherwise shrinks it onto a grey plate. (A superellipse got the plate.)
let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                  cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

/// Shadow offsets and blurs are in device pixels, not grid points, so they're scaled by this.
var pixelsPerPoint: CGFloat = 1

func shadow(_ ctx: CGContext, dy: CGFloat, blur: CGFloat, alpha: CGFloat) {
    ctx.setShadow(offset: CGSize(width: 0, height: dy * pixelsPerPoint), blur: blur * pixelsPerPoint,
                  color: rgb(0x000000, alpha))
}

func draw(in ctx: CGContext) {
    // Body: drop shadow as on system icons, then a white-to-pale-blue-grey gradient.
    ctx.saveGState()
    shadow(ctx, dy: -10, blur: 24, alpha: 0.30)
    ctx.addPath(body)
    ctx.setFillColor(rgb(0xDCE3EC))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF), rgb(0xDCE3EC)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Magnifying glass: handle, pale lens, dark rim.
    let lens = CGPoint(x: 476, y: 556), radius: CGFloat = 250
    let lensRect = CGRect(x: lens.x - radius, y: lens.y - radius, width: 2 * radius, height: 2 * radius)
    ctx.saveGState()
    shadow(ctx, dy: -6, blur: 14, alpha: 0.22)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setStrokeColor(rgb(0x1F2430))
    ctx.setLineCap(.round)
    ctx.setLineWidth(84)
    ctx.move(to: CGPoint(x: lens.x + (radius + 30) * cos(-.pi / 4), y: lens.y + (radius + 30) * sin(-.pi / 4)))
    ctx.addLine(to: CGPoint(x: 790, y: 242))
    ctx.strokePath()
    ctx.setFillColor(rgb(0xEAF3FF))
    ctx.fillEllipse(in: lensRect)
    ctx.setLineWidth(48)
    ctx.strokeEllipse(in: lensRect)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Wi-Fi symbol inside the lens: a dot and three arcs spanning 45° either side of vertical.
    let center = CGPoint(x: lens.x, y: lens.y - 96)
    let blue = rgb(0x0A84FF)
    ctx.setFillColor(blue)
    ctx.setStrokeColor(blue)
    ctx.fillEllipse(in: CGRect(x: center.x - 28, y: center.y - 28, width: 56, height: 56))
    ctx.setLineWidth(40)
    ctx.setLineCap(.round)
    for arcRadius: CGFloat in [66, 124, 182] {
        ctx.addArc(center: center, radius: arcRadius, startAngle: .pi / 4, endAngle: 3 * .pi / 4, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    pixelsPerPoint = CGFloat(pixels) / 1024
    ctx.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
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
