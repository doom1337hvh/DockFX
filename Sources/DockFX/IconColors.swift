import AppKit

/// A tile's picture as the Dock shows it, and its colour, for effects in its shape and colour:
/// the strongest colour in it, made bright. White for icons that are mostly grey.
@MainActor
enum IconColors {
    private static var pictures: [String: NSImage] = [:]
    private static var colors: [String: CGColor] = [:]
    private static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    /// The app's, folder's or file's icon; the Trash's own; nil for a minimised window.
    static func picture(for item: DockItem) -> NSImage? {
        guard let key = key(item) else { return nil }
        if let picture = pictures[key] { return picture }
        let picture = item.isTrash ? NSImage(named: NSImage.trashEmptyName)
            : item.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        pictures[key] = picture
        return picture
    }

    static func color(for item: DockItem) -> CGColor {
        guard let key = key(item) else { return white }
        if let color = colors[key] { return color }
        let color = picture(for: item).flatMap(strongestColor) ?? white
        colors[key] = color
        return color
    }

    private static func key(_ item: DockItem) -> String? {
        item.isTrash ? "trash" : item.url?.path
    }

    private static func strongestColor(in icon: NSImage) -> CGColor? {
        let size = 24
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        // Each pixel counts by how colourful and how solid it is, so the background of an icon
        // doesn't wash out its colour.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, total: CGFloat = 0
        var colourful: CGFloat = 0, solid: CGFloat = 0
        for i in 0..<(size * size) {
            let alpha = CGFloat(pixels[i * 4 + 3]) / 255
            guard alpha > 0.1 else { continue }
            let r = CGFloat(pixels[i * 4]) / 255 / alpha
            let g = CGFloat(pixels[i * 4 + 1]) / 255 / alpha
            let b = CGFloat(pixels[i * 4 + 2]) / 255 / alpha
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high > 0 ? (high - low) / high : 0
            let weight = alpha * (saturation * saturation + 0.01) * high
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
            colourful += alpha * saturation
            solid += alpha
        }
        guard total > 0, solid > 0, colourful / solid > 0.12 else { return nil }
        let color = NSColor(srgbRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return NSColor(hue: hue, saturation: min(1, max(saturation, 0.55)), brightness: max(brightness, 0.95), alpha: 1).cgColor
    }
}
