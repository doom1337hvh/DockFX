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
@MainActor
enum IconShapes {
    private static var cache: [String: CGImage] = [:]
    /// Where each picture is solid, as fractions of its square.
    private static var solidBoxes: [ObjectIdentifier: CGRect] = [:]
    private static let context = CIContext()

    /// The shape in a square of `side` points, the Dock's icon size (`DockItem.iconFrame`), with
    /// `margin` points of room around it.
    static func silhouette(_ picture: NSImage?, isApp: Bool, side: CGFloat, margin: CGFloat = 0,
                           scale: CGFloat) -> CGImage? {
        let key = "shape \(name(picture)) \(isApp) \(side) \(margin) \(scale)"
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
        return store(context.makeImage(), key)
    }

    /// A soft glow around the outside of the shape, out to about `reach` points, in a square of
    /// `side + 4 × reach` points. It starts just under the shape's edge, so it touches the icon,
    /// and is clear inside it, so the icon shows through untouched.
    static func glow(_ picture: NSImage?, isApp: Bool, side: CGFloat, reach: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "glow \(name(picture)) \(isApp) \(side) \(reach) \(scale)"
        if let image = cache[key] { return image }
        guard let shape = silhouette(picture, isApp: isApp, side: side, margin: reach * 2, scale: scale) else { return nil }
        let input = CIImage(cgImage: shape)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(reach * scale) / 2).cropped(to: input.extent)
        let inside = input.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 0.75 * scale])
        let outside = blurred.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inside])
        // Brightest right at the edge.
        let bright = outside.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 2)])
        return store(context.createCGImage(bright, from: input.extent), key)
    }

    /// A line `width` points wide just outside the shape, in a square of `side + 4 × width`
    /// points.
    static func outline(_ picture: NSImage?, isApp: Bool, side: CGFloat, width: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "outline \(name(picture)) \(isApp) \(side) \(width) \(scale)"
        if let image = cache[key] { return image }
        guard let shape = silhouette(picture, isApp: isApp, side: side, margin: width * 2, scale: scale) else { return nil }
        let input = CIImage(cgImage: shape)
        let grown = input.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: width * scale])
        let line = grown.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: input])
            .applyingGaussianBlur(sigma: 0.4 * Double(scale))
            .cropped(to: input.extent)
        return store(context.createCGImage(line, from: input.extent), key)
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
