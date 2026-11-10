import AppKit
import QuartzCore

/// Draws the looks (`Look`) as layers: on one icon, along the whole Dock, or all the time.
/// Each is drawn as if the Dock were along the bottom of the screen, so out from the Dock is up,
/// and turned for a Dock on the left or right.
@MainActor
struct Painter {
    /// An icon in the Dock, and the colour to draw on it.
    struct Tile {
        var icon: CGRect
        var color: CGColor
        /// Its tile in the Dock, for the effect on it to follow it (see `Stage`).
        var element: AXUIElement?
        /// Its picture, for effects in its shape (`IconShapes`); nil for the usual rounded square.
        var picture: NSImage?
        /// An app's tile, which the Dock draws its picture in at a different size from others'.
        var isApp = true
        /// Its notification badge's text, which effects in its shape go around.
        var badge: String?
    }

    let edge: DockEdge
    /// Pixels per point on the Dock's screen.
    let contentsScale: CGFloat
    /// How the moment's effect looks and moves: strength, size, speed and so on.
    let style: EffectStyle

    /// How much longer than normal effects take.
    private var pace: Double { style.pace }
    private var strength: CGFloat { CGFloat(style.strength) }
    private var size: CGFloat { CGFloat(style.size) }

    // MARK: - One icon

    /// `look` on one icon, starting after `delay`. Returns its layer and when it's over.
    /// `density` thins out the sparkles' dots, for many icons at once.
    func icon(_ look: Look, on tile: Tile, delay: Double = 0, density: Float = 1) -> (layer: CALayer, duration: Double) {
        let container = oriented(tile.icon)
        let side = container.bounds.width
        // What's in the icon's shape stays the right way up, the way the Dock draws the icon
        // and its badge, while sparkles still go out from the Dock.
        let upright = CALayer()
        upright.bounds = container.bounds
        upright.position = container.bounds.center
        upright.setAffineTransform(self.upright)
        container.addSublayer(upright)
        let start = CACurrentMediaTime() + delay
        var duration = 0.0
        switch look {
        case .off:
            break
        case .glow:
            duration = 1.0 * pace
            let glow = glow(around: tile, side: side, strength: strength)
            glow.position = upright.bounds.center
            animate(glow, "opacity", [0, 1, 0.8, 0], times: [0, 0.2, 0.55, 1], duration: duration, start: start)
            upright.addSublayer(glow)
        case .shine:
            duration = 0.75 * pace
            let shape = IconShapes.silhouette(tile.picture, isApp: tile.isApp, badge: tile.badge, .cutOut, side: side,
                                              scale: contentsScale)
            upright.addSublayer(shine(over: upright.bounds, shape: shape, bandWidth: side * 0.55 * size,
                                      tint: tile.color, strength: 1.15 * strength, duration: duration, start: start))
        case .sparkles:
            // A brief soft flash in the icon's shape, as if the dots were light coming off it.
            let flash = glow(around: tile, side: side, strength: 0.5 * strength)
            flash.position = upright.bounds.center
            animate(flash, "opacity", [0, 1, 0], times: [0, 0.25, 1], duration: 0.6 * pace, start: start)
            upright.addSublayer(flash)
            let burst = dots(over: container.bounds, color: tile.color, start: start, density: density)
            container.addSublayer(burst.layer)
            duration = burst.duration
        case .ripple:
            let rings = max(1, style.rings)
            duration = (0.85 + Double(rings - 1) * 0.2) * pace
            for index in 0..<rings {
                let ring = ripple(around: tile, side: side, width: max(1.2, side * 0.045 * (0.6 + 0.4 * strength)),
                                  reach: side * 0.4 * size, opacity: Float(min(1, 0.95 * strength)),
                                  duration: 0.85 * pace, start: start + Double(index) * 0.2 * pace)
                ring.position = upright.bounds.center
                upright.addSublayer(ring)
            }
        }
        return (container, delay + duration)
    }

    // MARK: - Along the Dock

    /// `look` along the whole Dock, once. Returns its layer and when it's over.
    func along(_ look: Look, dock: CGRect, tiles: [Tile], tint: CGColor) -> (layer: CALayer, duration: Double) {
        let container = oriented(dock)
        let bounds = container.bounds
        let tiles = tiles.map { tile in
            var tile = tile
            tile.icon = local(tile.icon, in: dock)
            return tile
        }
        let start = CACurrentMediaTime()
        var duration = 0.0
        switch look {
        case .off:
            break
        case .glow, .sparkles:
            // A wave of the icon effect, from one end of the Dock to the other.
            for tile in tiles {
                let position = (tile.icon.midX - bounds.minX) / max(bounds.width, 1)
                let delay = Double(position) * 0.5 * pace
                let effect = icon(look, on: tile, delay: delay, density: 0.45)
                // Already the right way round inside the Dock's turned layer.
                effect.layer.setAffineTransform(.identity)
                container.addSublayer(effect.layer)
                duration = max(duration, effect.duration)
            }
        case .shine:
            duration = (0.7 + Double(bounds.width) / 1800) * pace
            container.addSublayer(shine(over: bounds, shape: nil, bandWidth: bounds.height * 1.6 * size, tint: tint,
                                        strength: 0.9 * strength, duration: duration, start: start))
        case .ripple:
            duration = 1.1 * pace
            for index in 0..<max(1, style.rings) {
                container.addSublayer(dockRing(bounds, tiles: tiles, duration: duration,
                                               start: start + Double(index) * 0.25 * pace,
                                               opacity: Float(min(1, strength))))
            }
            duration += Double(max(1, style.rings) - 1) * 0.25 * pace
        }
        return (container, duration)
    }

    // MARK: - All the time

    /// `look` along the Dock, over and over, for good.
    func ambient(_ look: Look, dock: CGRect, tiles: [Tile], tint: CGColor) -> CALayer {
        let container = oriented(dock)
        let bounds = container.bounds
        let tiles = tiles.map { tile in
            var tile = tile
            tile.icon = local(tile.icon, in: dock)
            return tile
        }
        let now = CACurrentMediaTime()
        switch look {
        case .off:
            break
        case .glow:
            // A slow wave of light moving along the icons.
            let period = 2.6 * pace
            for tile in tiles {
                let glow = glow(around: tile, side: tile.icon.width, strength: 0.7 * strength)
                glow.position = tile.icon.center
                glow.setAffineTransform(upright)
                let position = Double((tile.icon.midX - bounds.minX) / max(bounds.width, 1))
                animate(glow, "opacity", [0.08, 0.8, 0.08], times: [0, 0.5, 1], duration: period,
                        start: now - (1 - position) * period, timing: .easeInEaseOut, period: period)
                container.addSublayer(glow)
            }
        case .shine:
            let period = 6.0 * pace
            container.addSublayer(shine(over: bounds, shape: nil, bandWidth: bounds.height * 1.6 * size, tint: tint,
                                        strength: 0.6 * strength, duration: 1.8 * pace, start: now + 0.5, period: period))
        case .sparkles:
            for tile in tiles {
                container.addSublayer(twinkles(over: tile.icon, color: tile.color, now: now))
            }
        case .ripple:
            for index in 0..<max(1, style.rings) {
                container.addSublayer(dockRing(bounds, tiles: tiles, duration: 1.8 * pace,
                                               start: now + 0.3 + Double(index) * 0.35 * pace,
                                               period: 4.5 * pace, opacity: Float(min(1, 0.6 * strength))))
            }
        }
        return container
    }

    // MARK: - Pieces

    /// A soft glow around an icon, in its own shape, brightest at its edge and reaching further
    /// out the bigger the style's size. The icon itself shows through untouched.
    private func glow(around tile: Tile, side: CGFloat, strength: CGFloat) -> CALayer {
        let shape = IconShapes.glow(tile.picture, isApp: tile.isApp, badge: tile.badge, side: side,
                                    reach: side * 0.2 * size, scale: contentsScale)
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: shape.size, height: shape.size)
        layer.backgroundColor = tile.color.withAlpha(min(1, 0.8 * strength))
        layer.mask = mask(shape.image, layer.bounds)
        return layer
    }

    /// A ring in an icon's shape that spreads out `reach` points from it and fades.
    private func ripple(around tile: Tile, side: CGFloat, width: CGFloat, reach: CGFloat, opacity: Float,
                        duration: Double, start: CFTimeInterval) -> CALayer {
        let shape = IconShapes.outline(tile.picture, isApp: tile.isApp, badge: tile.badge, side: side, width: width,
                                       scale: contentsScale)
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: shape.size, height: shape.size)
        layer.backgroundColor = tile.color
        layer.mask = mask(shape.image, layer.bounds)
        animate(layer, "transform.scale", [1, 1 + reach * 2 / side], duration: duration, start: start)
        animate(layer, "opacity", [opacity, 0], duration: duration, start: start)
        return layer
    }

    private func mask(_ image: CGImage?, _ bounds: CGRect) -> CALayer {
        let mask = CALayer()
        mask.frame = bounds
        mask.contents = image
        return mask
    }

    /// A band of light that sweeps across `rect`, kept inside `shape` (an icon's, from
    /// `IconShapes`), or else the Dock's rounded bar.
    private func shine(over rect: CGRect, shape: CGImage?, bandWidth: CGFloat, tint: CGColor,
                       strength: CGFloat, duration: Double, start: CFTimeInterval, period: Double? = nil) -> CALayer {
        let holder = CALayer()
        holder.frame = rect
        let bounds = CGRect(origin: .zero, size: rect.size)
        if let shape {
            holder.mask = mask(shape, bounds)
        } else {
            let mask = CAShapeLayer()
            mask.path = Self.roundedPath(bounds, radius: dockCornerRadius(bounds))
            holder.mask = mask
        }

        let light = CGColor.white.mixed(with: tint, 0.25)
        let band = CAGradientLayer()
        band.colors = [0, 0.85, 0].map { light.withAlpha(min(1, $0 * strength)) }
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.bounds = CGRect(x: 0, y: 0, width: bandWidth, height: rect.height * 2)
        band.position = CGPoint(x: -bandWidth, y: rect.height / 2)
        // Leaning, like light caught on glass.
        band.setAffineTransform(CGAffineTransform(rotationAngle: -0.35))
        band.contentsScale = contentsScale
        animate(band, "position.x", [-bandWidth, rect.width + bandWidth], duration: duration, start: start,
                timing: .easeInEaseOut, period: period)
        holder.addSublayer(band)
        return holder
    }

    /// A burst of small glowing dots from the edge of an icon in `rect`, starting at `start`:
    /// quick at first, then slowing as they drift up and apart, and fading. One in five is
    /// bigger and fainter, as if out of focus.
    private func dots(over rect: CGRect, color: CGColor, start: CFTimeInterval,
                      density: Float) -> (layer: CALayer, duration: Double) {
        let holder = CALayer()
        holder.frame = rect
        let side = min(rect.width, rect.height)
        let middle = CGPoint(x: rect.width / 2, y: rect.height / 2)
        let count = max(3, Int((14 * Double(density) * style.amount).rounded()))
        let peak = Float(min(1, strength))
        var duration = 0.0
        for index in 0..<count {
            let soft = index % 5 == 4
            let diameter = (soft ? CGFloat.random(in: 7...11) : CGFloat.random(in: 1.8...4.4)) * dotScale(side)
            let dot = dot(diameter: diameter, color: color, soft: soft)
            // From just outside the icon's edge, mostly upward.
            let angle = CGFloat.random(in: -0.2...(.pi + 0.2))
            let from = CGPoint(x: middle.x + cos(angle) * side * 0.44, y: middle.y + sin(angle) * side * 0.44)
            let travel = side * CGFloat.random(in: 0.35...0.9) * size
            let to = CGPoint(x: from.x + cos(angle) * travel * 0.6, y: from.y + max(0, sin(angle)) * travel * 0.4 + travel * 0.55)
            let path = CGMutablePath()
            path.move(to: from)
            path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2 + CGFloat.random(in: -0.15...0.15) * side,
                                                       y: (from.y + to.y) / 2))
            let lifetime = Double.random(in: 0.9...1.5) * pace
            let begin = start + Double.random(in: 0...0.15) * pace
            dot.position = to
            animate(dot, "position", [], path: path, duration: lifetime, start: begin, timing: nil,
                    curve: Self.settle)
            let brightness = soft ? peak * 0.6 : peak
            animate(dot, "opacity", [0, brightness, brightness * 0.75, 0], times: [0, 0.1, 0.5, 1],
                    duration: lifetime, start: begin, timing: .linear)
            animate(dot, "transform.scale", [0.3, 1, 0.55], times: [0, 0.15, 1], duration: lifetime, start: begin)
            holder.addSublayer(dot)
            duration = max(duration, begin - start + lifetime)
        }
        return (holder, duration)
    }

    /// A few glowing dots that rise gently off an icon now and then, for good.
    private func twinkles(over rect: CGRect, color: CGColor, now: CFTimeInterval) -> CALayer {
        let holder = CALayer()
        holder.frame = rect
        let side = min(rect.width, rect.height)
        let peak = Float(min(1, 0.9 * strength))
        for _ in 0..<max(1, Int((2 * style.amount).rounded())) {
            let dot = dot(diameter: CGFloat.random(in: 2.2...4) * dotScale(side), color: color, soft: false)
            let from = CGPoint(x: side * CGFloat.random(in: 0.2...0.8), y: side * CGFloat.random(in: 0.6...0.85))
            let to = CGPoint(x: from.x + side * CGFloat.random(in: -0.12...0.12),
                             y: from.y + side * CGFloat.random(in: 0.3...0.55) * size)
            let path = CGMutablePath()
            path.move(to: from)
            path.addLine(to: to)
            let period = Double.random(in: 2.6...4.2) * pace
            let lifetime = period * 0.65
            // Each at its own point in its round, so they don't rise together.
            let begin = now - Double.random(in: 0...period)
            dot.position = from
            animate(dot, "position", [], path: path, duration: lifetime, start: begin, timing: nil,
                    curve: Self.settle, period: period)
            animate(dot, "opacity", [0, peak, 0], times: [0, 0.3, 1], duration: lifetime, start: begin,
                    timing: .linear, period: period)
            animate(dot, "transform.scale", [0.5, 1, 0.6], times: [0, 0.3, 1], duration: lifetime, start: begin,
                    period: period)
            holder.addSublayer(dot)
        }
        return holder
    }

    /// One glowing dot: a bright core, nearly white, in a soft glow of `color`; or, `soft`, a
    /// faint blur of it.
    private func dot(diameter: CGFloat, color: CGColor, soft: Bool) -> CALayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        // Room for its glow around it.
        layer.bounds = CGRect(x: 0, y: 0, width: diameter * 2.4, height: diameter * 2.4)
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        if soft {
            layer.colors = [color.withAlpha(0.45), color.withAlpha(0.25), color.withAlpha(0)]
            layer.locations = [0, 0.4, 1]
        } else {
            let core = CGColor.white.mixed(with: color, CGFloat.random(in: 0.3...0.6))
            layer.colors = [core, core, color.withAlpha(0.5), color.withAlpha(0)]
            // The core is 0.42 of the way out.
            layer.locations = [0, 0.3, 0.42, 1]
        }
        layer.contentsScale = contentsScale
        return layer
    }

    /// Dots are sized to the icon and the style's size; past full strength, a little bigger.
    private func dotScale(_ side: CGFloat) -> CGFloat {
        side / 45 * size * max(1, sqrt(strength))
    }

    /// Off quickly, then slowing right down, like something tossed up that floats.
    private static let settle = CAMediaTimingFunction(controlPoints: 0.15, 0.85, 0.3, 1)

    /// A ring in the Dock's shape that spreads out from it, in the icons' colours along it.
    private func dockRing(_ bounds: CGRect, tiles: [Tile], duration: Double, start: CFTimeInterval,
                          period: Double? = nil, opacity: Float) -> CALayer {
        // In proportion to the Dock's thickness: 26 points for a 59-point Dock.
        let reach = bounds.height * 0.44 * size
        let room = reach + bounds.height * 0.2
        let gradient = CAGradientLayer()
        gradient.frame = bounds.insetBy(dx: -room, dy: -room)
        let colors = tiles.sorted { $0.icon.midX < $1.icon.midX }
        let width = max(gradient.frame.width, 1)
        if colors.count > 1 {
            gradient.colors = colors.map(\.color)
            gradient.locations = colors.map { NSNumber(value: Double(($0.icon.midX - gradient.frame.minX) / width)) }
        } else {
            let color = colors.first?.color ?? .white
            gradient.colors = [color, color]
        }
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.contentsScale = contentsScale

        let ring = CAShapeLayer()
        ring.frame = CGRect(origin: .zero, size: gradient.frame.size)
        ring.fillColor = nil
        ring.strokeColor = .black
        ring.lineWidth = 2.5
        ring.contentsScale = contentsScale
        let from = bounds.offsetBy(dx: room - bounds.minX, dy: room - bounds.minY)
        let to = from.insetBy(dx: -reach, dy: -reach)
        let radius = dockCornerRadius(bounds)
        ring.path = Self.roundedPath(to, radius: radius + reach)
        animate(ring, "path", [Self.roundedPath(from, radius: radius), Self.roundedPath(to, radius: radius + reach)],
                duration: duration, start: start, period: period)
        let lineWidth = bounds.height * 0.05 * (0.6 + 0.4 * strength)
        animate(ring, "lineWidth", [lineWidth, lineWidth / 3], duration: duration, start: start, period: period)
        gradient.mask = ring
        animate(gradient, "opacity", [opacity, 0], duration: duration, start: start, period: period)
        return gradient
    }

    private func dockCornerRadius(_ bounds: CGRect) -> CGFloat {
        min(bounds.height * 0.38, bounds.width / 2)
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    // MARK: - Geometry and timing

    /// Undoes `oriented`'s turn, for what has to stay the right way up on screen.
    private var upright: CGAffineTransform {
        switch edge {
        case .bottom: .identity
        case .left: CGAffineTransform(rotationAngle: .pi / 2)
        case .right: CGAffineTransform(rotationAngle: -.pi / 2)
        }
    }

    /// A layer over `rect`, turned so that inside it, out from the Dock is up.
    private func oriented(_ rect: CGRect) -> CALayer {
        let layer = CALayer()
        let vertical = edge != .bottom
        layer.bounds = CGRect(x: 0, y: 0, width: vertical ? rect.height : rect.width,
                              height: vertical ? rect.width : rect.height)
        layer.position = rect.center
        switch edge {
        case .bottom: break
        case .left: layer.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2))
        case .right: layer.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))
        }
        return layer
    }

    /// Where `rect` is inside `oriented(outer)`.
    private func local(_ rect: CGRect, in outer: CGRect) -> CGRect {
        let dx = rect.midX - outer.midX, dy = rect.midY - outer.midY
        let center: CGPoint
        switch edge {
        case .bottom: return rect.offsetBy(dx: -outer.minX, dy: -outer.minY)
        case .left: center = CGPoint(x: outer.height / 2 - dy, y: outer.width / 2 + dx)
        case .right: center = CGPoint(x: outer.height / 2 + dy, y: outer.width / 2 - dx)
        }
        return CGRect(x: center.x - rect.height / 2, y: center.y - rect.width / 2, width: rect.height, height: rect.width)
    }

    /// Animates `keyPath` through `values` (evenly spaced, or at `times`), or along `path`, from
    /// `start`, holding the first value until then and the last after; eased by `timing`, or by
    /// `curve` if given. With `period`, it plays again every `period` seconds, for good.
    private func animate(_ layer: CALayer, _ keyPath: String, _ values: [Any], times: [NSNumber]? = nil,
                         path: CGPath? = nil, duration: Double, start: CFTimeInterval,
                         timing: CAMediaTimingFunctionName? = .easeOut, curve: CAMediaTimingFunction? = nil,
                         period: Double? = nil) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        if let path {
            animation.path = path
        } else {
            animation.values = values
            animation.keyTimes = times
        }
        animation.duration = duration
        animation.timingFunction = curve ?? CAMediaTimingFunction(name: timing ?? .easeOut)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        var added: CAAnimation = animation
        if let period {
            let group = CAAnimationGroup()
            group.animations = [animation]
            group.duration = period
            group.repeatCount = .infinity
            added = group
        }
        added.beginTime = start
        added.fillMode = animation.fillMode
        added.isRemovedOnCompletion = false
        layer.add(added, forKey: keyPath)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CGColor {
    func withAlpha(_ alpha: CGFloat) -> CGColor {
        copy(alpha: alpha) ?? self
    }

    /// This colour moved `amount` of the way to `other`.
    func mixed(with other: CGColor, _ amount: CGFloat) -> CGColor {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let a = converted(to: space, intent: .defaultIntent, options: nil)?.components,
              let b = other.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              a.count >= 3, b.count >= 3 else { return self }
        let mix = (0..<3).map { a[$0] + (b[$0] - a[$0]) * amount }
        return CGColor(srgbRed: mix[0], green: mix[1], blue: mix[2], alpha: 1)
    }
}
