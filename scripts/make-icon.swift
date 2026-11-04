// Draws DockFX's app icon and writes Resources/AppIcon.icns and docs/icon.png.
//
//   swift scripts/make-icon.swift
//
// A rounded square in the macOS icon grid, with a Dock of four icons on a night sky: one of
// them glowing, with a ripple around it and sparkles rising out of it.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A four-pointed sparkle `size` across, its sides curving in towards the middle.
func sparkle(at center: CGPoint, size: CGFloat) -> CGPath {
    let r = size / 2, bulge = r * 0.16
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: center.y + r))
    path.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y), control: CGPoint(x: center.x + bulge, y: center.y + bulge))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r), control: CGPoint(x: center.x + bulge, y: center.y - bulge))
    path.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y), control: CGPoint(x: center.x - bulge, y: center.y - bulge))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r), control: CGPoint(x: center.x - bulge, y: center.y + bulge))
    return path
}

func drawIcon(in context: CGContext) {
    // Core Graphics' origin is bottom-left, so y grows upward here.
    // The body: 824 pt with a continuous-looking corner, per Apple's icon grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = rounded(body, 186)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(bodyPath)
    context.setFillColor(color(0x000000))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    // A night sky, lighter towards the Dock.
    context.drawLinearGradient(gradient([color(0x0B1026), color(0x1E1B4B), color(0x312E81)]),
                               start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // The Dock: a bar of frosted glass with four icons.
    let bar = CGRect(x: 190, y: 250, width: 644, height: 140)
    let tile: CGFloat = 104
    let gap = (bar.width - 4 * tile) / 5
    let colors: [(UInt32, UInt32)] = [(0x7DD3FC, 0x2563EB), (0x86EFAC, 0x16A34A), (0xFDBA74, 0xEA580C), (0xF0ABFC, 0xA21CAF)]
    let lit = 2
    let litCenter = CGPoint(x: bar.minX + gap + tile / 2 + CGFloat(lit) * (tile + gap), y: bar.midY)

    // The glow of the lit icon spills over the bar and the sky above it.
    context.drawRadialGradient(gradient([color(0xFDBA74, 0.75), color(0xF97316, 0.25), color(0xF97316, 0)], [0, 0.45, 1]),
                               startCenter: litCenter, startRadius: 0, endCenter: litCenter, endRadius: 250, options: [])

    context.addPath(rounded(bar, 58))
    context.setFillColor(color(0xFFFFFF, 0.14))
    context.fillPath()
    context.addPath(rounded(bar.insetBy(dx: 2, dy: 2), 56))
    context.setStrokeColor(color(0xFFFFFF, 0.35))
    context.setLineWidth(4)
    context.strokePath()

    for (index, (top, bottom)) in colors.enumerated() {
        let rect = CGRect(x: bar.minX + gap + CGFloat(index) * (tile + gap), y: bar.midY - tile / 2, width: tile, height: tile)
        context.saveGState()
        context.addPath(rounded(rect, 26))
        context.clip()
        context.drawLinearGradient(gradient([color(top), color(bottom)]),
                                   start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        context.restoreGState()
    }

    // A ripple spreading from the lit icon.
    let ripple = CGRect(x: litCenter.x - tile / 2, y: litCenter.y - tile / 2, width: tile, height: tile).insetBy(dx: -26, dy: -26)
    context.addPath(rounded(ripple, 44))
    context.setStrokeColor(color(0xFED7AA, 0.85))
    context.setLineWidth(7)
    context.strokePath()

    // Sparkles rising out of it.
    let sparkles: [(CGPoint, CGFloat)] = [
        (CGPoint(x: litCenter.x - 30, y: 640), 210),
        (CGPoint(x: litCenter.x + 140, y: 540), 96),
        (CGPoint(x: litCenter.x - 210, y: 560), 70),
        (CGPoint(x: litCenter.x + 100, y: 770), 58),
        (CGPoint(x: litCenter.x - 160, y: 760), 40),
    ]
    for (center, size) in sparkles {
        context.saveGState()
        context.setShadow(offset: .zero, blur: size * 0.3, color: color(0xFDE68A, 0.9))
        context.addPath(sparkle(at: center, size: size))
        context.setFillColor(color(0xFFFBEB))
        context.fillPath()
        context.restoreGState()
    }
    context.restoreGState()
}

func png(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    context.interpolationQuality = .high
    drawIcon(in: context)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try png(size: 1024).write(to: root.appendingPathComponent("docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
