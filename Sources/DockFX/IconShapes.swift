import AppKit
import CoreImage

/// The shape of an icon as the Dock draws it, taken from its picture, for effects that follow
/// its outline: a glow around it, a shine across it, ripples spreading from it. Without a
/// picture, it's the rounded square app icons share, or, for a minimised window, the shape of a
/// window's preview. Each is a mask: white where it shows.
///
/// The pictures macOS gives other apps aren't drawn at quite the Dock's size, so each is
/// scaled to it: an app icon's rounded square takes up 80.5% of the Dock's icon size, as in
/// Apple's icon grid, and the Dock draws folders, the Trash and the like 72% of it wide.
///
/// An icon's notification badge is part of its shape, so a glow or ripple goes around the
/// badge rather than over it; a shine is kept off it.
@MainActor
enum IconShapes {
    /// What a shape does with the icon's notification badge.
    enum Badge {
        /// Part of the shape: effects go around it.
        case joined
        /// Cut out of the shape: effects inside the icon stay off it.
        case cutOut
    }

    private static var cache: [String: CGImage] = [:]
    /// Where each picture is solid, as fractions of its square.
    private static var solidBoxes: [ObjectIdentifier: CGRect] = [:]
    private static let context = CIContext()

    /// The shape in a square of `side` points, the Dock's icon size (`DockItem.iconFrame`), with
    /// `margin` points of room around it, and `badge`, the badge's text, joined to it or cut out.
    static func silhouette(_ picture: NSImage?, isApp: Bool, badge: String?, _ use: Badge = .joined,
                           side: CGFloat, margin: CGFloat = 0, scale: CGFloat) -> CGImage? {
        let key = "shape \(name(picture)) \(isApp) \(badge ?? "") \(use) \(side) \(margin) \(scale)"
        if let image = cache[key] { return image }
        let pixels = Int(((side + margin * 2) * scale).rounded())
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let middle = CGPoint(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2)
        let iconSize = side * scale
        if let picture, let box = solidBox(of: picture), box.width > 0, box.height > 0 {
            // Drawn so its solid part is the size the Dock draws it at, in the middle.
            let drawn = isApp ? 0.805 * iconSize / max(box.width, box.height) : 0.72 * iconSize / box.width
            let origin = CGPoint(x: middle.x - box.midX * drawn, y: middle.y - box.midY * drawn)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            picture.draw(in: CGRect(origin: origin, size: CGSize(width: drawn, height: drawn)))
            NSGraphicsContext.restoreGraphicsState()
            // Solid wherever the picture mostly is, with its edge kept smooth, and its faint
            // drop shadow left out.
            if let data = context.data {
                let bytes = data.bindMemory(to: UInt8.self, capacity: pixels * pixels * 4)
                for i in 0..<(pixels * pixels) {
                    let alpha = Int(bytes[i * 4 + 3])
                    let value = UInt8(min(255, max(0, (alpha - 90) * 255 / 110)))
                    bytes[i * 4] = value
                    bytes[i * 4 + 1] = value
                    bytes[i * 4 + 2] = value
                    bytes[i * 4 + 3] = value
                }
            }
        } else {
            // A minimised window shows as a preview of it, nearly as wide as the tile; most
            // windows are about 16 by 10.
            let size = isApp ? CGSize(width: 0.805 * iconSize, height: 0.805 * iconSize)
                             : CGSize(width: 0.94 * iconSize, height: 0.585 * iconSize)
            let radius = isApp ? size.width * 0.225 : 0.067 * iconSize
            let rect = CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2,
                              width: size.width, height: size.height)
            context.setFillColor(.white)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        if let badge {
            let pill = badgeFrame(badge, side: side)
            let rect = CGRect(x: (margin + pill.minX) * scale, y: (margin + pill.minY) * scale,
                              width: pill.width * scale, height: pill.height * scale)
            let radius = rect.height / 2
            context.setFillColor(.white)
            context.setBlendMode(use == .joined ? .normal : .clear)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        return store(context.makeImage(), key)
    }

    /// Where the Dock draws a notification badge, in a square of `side` points counting up from
    /// its bottom left: a pill 40% of the icon size tall, at least as wide as it is tall, wide
    /// enough for its text, its right end at the square's right edge, and its top just above
    /// the square's.
    static func badgeFrame(_ badge: String, side: CGFloat) -> CGRect {
        let height = 0.4 * side
        let text = NSAttributedString(string: badge, attributes: [.font: NSFont.systemFont(ofSize: 0.18 * side)])
        let width = max(height, text.size().width + 0.127 * side)
        return CGRect(x: side - width, y: 0.611 * side, width: width, height: height)
    }

    /// How far a badge reaches above the icon's square.
    private static func badgeOverhang(_ badge: String?, side: CGFloat) -> CGFloat {
        badge == nil ? 0 : 0.012 * side
    }

    /// A soft glow around the outside of the shape and its badge, out to about `reach` points,
    /// in a square `size` points across, centred on the icon. It starts just under the shape's
    /// edge, so it touches the icon, and is clear inside it, so the icon and badge show through
    /// untouched.
    static func glow(_ picture: NSImage?, isApp: Bool, badge: String?, side: CGFloat, reach: CGFloat,
                     scale: CGFloat) -> (image: CGImage?, size: CGFloat) {
        let margin = max(reach * 2, badgeOverhang(badge, side: side) + reach)
        let size = side + margin * 2
        let key = "glow \(name(picture)) \(isApp) \(badge ?? "") \(side) \(reach) \(scale)"
        if let image = cache[key] { return (image, size) }
        guard let shape = silhouette(picture, isApp: isApp, badge: badge, side: side, margin: margin, scale: scale)
        else { return (nil, size) }
        let input = CIImage(cgImage: shape)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(reach * scale) / 2).cropped(to: input.extent)
        let inside = input.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 0.75 * scale])
        let outside = blurred.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inside])
        // Brightest right at the edge.
        let bright = outside.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 2)])
        return (store(context.createCGImage(bright, from: input.extent), key), size)
    }

    /// A line `width` points wide just outside the shape and its badge, in a square `size`
    /// points across, centred on the icon.
    static func outline(_ picture: NSImage?, isApp: Bool, badge: String?, side: CGFloat, width: CGFloat,
                        scale: CGFloat) -> (image: CGImage?, size: CGFloat) {
        let margin = badgeOverhang(badge, side: side) + width * 2
        let size = side + margin * 2
        let key = "outline \(name(picture)) \(isApp) \(badge ?? "") \(side) \(width) \(scale)"
        if let image = cache[key] { return (image, size) }
        guard let shape = silhouette(picture, isApp: isApp, badge: badge, side: side, margin: margin, scale: scale)
        else { return (nil, size) }
        let input = CIImage(cgImage: shape)
        let grown = input.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: width * scale])
        let line = grown.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: input])
            .applyingGaussianBlur(sigma: 0.4 * Double(scale))
            .cropped(to: input.extent)
        return (store(context.createCGImage(line, from: input.extent), key), size)
    }

    /// Where `picture` is solid, as fractions of its square.
    private static func solidBox(of picture: NSImage) -> CGRect? {
        let id = ObjectIdentifier(picture)
        if let box = solidBoxes[id] { return box }
        let size = 128
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        picture.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        var minX = size, minY = size, maxX = -1, maxY = -1
        for row in 0..<size {
            for column in 0..<size where bytes[(row * size + column) * 4 + 3] > 128 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Rows in memory run from the top; the box counts from the bottom.
        let box = CGRect(x: CGFloat(minX) / CGFloat(size), y: CGFloat(size - 1 - maxY) / CGFloat(size),
                         width: CGFloat(maxX - minX + 1) / CGFloat(size), height: CGFloat(maxY - minY + 1) / CGFloat(size))
        solidBoxes[id] = box
        return box
    }

    private static func name(_ picture: NSImage?) -> String {
        picture.map { "\(ObjectIdentifier($0).hashValue)" } ?? "rounded"
    }

    private static func store(_ image: CGImage?, _ key: String) -> CGImage? {
        // Sizes change as Size is dragged in Settings; start again rather than keep them all.
        if cache.count > 400 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
