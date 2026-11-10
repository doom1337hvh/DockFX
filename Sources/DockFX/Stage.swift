import AppKit
import QuartzCore

/// A see-through window just above the Dock that the effects are drawn in. Clicks go through
/// it, and it's only on screen while something plays, so it never sits over a full-screen video.
///
/// While something plays, the effects follow the Dock: each moves with the icon it's on, or with
/// the bar, and fades as the Dock slides out of sight.
@MainActor
final class Stage {
    /// When the Dock has slid out of sight under something that was playing.
    var onDockHidden: (() -> Void)?

    private let dock: Dock
    private var window: NSWindow?
    private let root = CALayer()
    /// The screen the window is on.
    private var screen = CGRect.zero
    private var effects: [Effect] = []
    private var ambient: Effect?
    /// What the all-the-time effect was drawn for, to redraw it only when that changes.
    private var ambientDrawnFor: String?
    private var tracker: Timer?
    /// Until when to keep following the Dock for the all-the-time effect alone.
    private var followUntil: CFTimeInterval = 0

    /// An effect on stage, and what it moves with: the tile it's on, or else the whole bar.
    private final class Effect {
        let layer: CALayer
        /// Where the layer was put and how it was turned, and where the bar and the tile's icon
        /// were then, on screen.
        let position: CGPoint
        let transform: CGAffineTransform
        let bar: CGRect
        let tile: AXUIElement?
        let icon: CGRect

        init(layer: CALayer, bar: CGRect, tile: AXUIElement? = nil, icon: CGRect = .zero) {
            self.layer = layer
            position = layer.position
            transform = layer.affineTransform()
            self.bar = bar
            self.tile = tile
            self.icon = icon
        }
    }

    init(dock: Dock) {
        self.dock = dock
    }

    /// `style`'s look on each of `tiles`, one after another `stagger` seconds apart.
    func play(_ style: EffectStyle, on tiles: [Painter.Tile], stagger: Double = 0, density: Float = 1,
              over layout: DockLayout) {
        guard style.look != .off, !tiles.isEmpty else { return }
        let painter = open(over: layout, style: style)
        // Following each tile takes a read of the Dock every frame, so only for a few.
        let followsTiles = tiles.count <= 3
        for (index, tile) in tiles.enumerated() {
            let drawn = painter.icon(style.look, on: local(tile), delay: Double(index) * stagger, density: density)
            show(Effect(layer: drawn.layer, bar: layout.frame, tile: followsTiles ? tile.element : nil,
                        icon: tile.icon), for: drawn.duration)
        }
    }

    /// `style`'s look along the whole Dock, once.
    func playAlong(_ style: EffectStyle, tiles: [Painter.Tile], tint: CGColor, over layout: DockLayout) {
        guard style.look != .off else { return }
        let painter = open(over: layout, style: style)
        let drawn = painter.along(style.look, dock: local(layout.frame), tiles: tiles.map(local), tint: tint)
        show(Effect(layer: drawn.layer, bar: layout.frame), for: drawn.duration)
    }

    /// Keeps `style`'s look going along the Dock until `hideAmbient`.
    func showAmbient(_ style: EffectStyle, tiles: [Painter.Tile], tint: CGColor, over layout: DockLayout) {
        let drawnFor = "\(style) \(layout.frame) \(tiles.map(\.icon)) \(tiles.map(\.color)) \(tiles.map(\.badge)) \(tint)"
        guard drawnFor != ambientDrawnFor else { return }
        hideAmbient()
        let painter = open(over: layout, style: style)
        let layer = painter.ambient(style.look, dock: local(layout.frame), tiles: tiles.map(local), tint: tint)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.insertSublayer(layer, at: 0)
        CATransaction.commit()
        ambient = Effect(layer: layer, bar: layout.frame)
        ambientDrawnFor = drawnFor
    }

    func hideAmbient() {
        guard let ambient else { return }
        ambient.layer.removeFromSuperlayer()
        self.ambient = nil
        ambientDrawnFor = nil
        closeIfIdle()
    }

    /// Follows the Dock for the next `seconds`, while the all-the-time effect shows: after the
    /// pointer leaves the Dock, say, when it might hide.
    func follow(for seconds: Double) {
        guard ambient != nil else { return }
        followUntil = max(followUntil, CACurrentMediaTime() + seconds)
        startTracking()
    }

    // MARK: - Following the Dock

    private func startTracking() {
        guard tracker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tracker = timer
    }

    private func stopTracking() {
        tracker?.invalidate()
        tracker = nil
    }

    /// Moves everything on stage with the Dock, and fades it as much of the Dock as has slid
    /// out of sight.
    private func track() {
        let following = !effects.isEmpty || (ambient != nil && CACurrentMediaTime() < followUntil)
        guard following else {
            stopTracking()
            return
        }
        guard let bar = dock.barFrame() else { return }
        let shown = min(1, screen.intersection(bar).area / max(bar.area, 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = Float(shown)
        for effect in effects + [ambient].compactMap({ $0 }) {
            move(effect, with: bar)
        }
        CATransaction.commit()
        if shown < 0.01 {
            // Gone with the Dock.
            for effect in effects {
                effect.layer.removeFromSuperlayer()
            }
            effects = []
            hideAmbient()
            closeIfIdle()
            onDockHidden?()
        }
    }

    /// Moves an effect with its tile, and grows or shrinks it with the tile too, as when
    /// magnification makes the icon under the pointer bigger; or else moves it with the bar.
    private func move(_ effect: Effect, with bar: CGRect) {
        var dx = bar.midX - effect.bar.midX, dy = bar.midY - effect.bar.midY
        if let tile = effect.tile, let icon = dock.iconFrame(of: tile), effect.icon.width > 0 {
            dx = icon.midX - effect.icon.midX
            dy = icon.midY - effect.icon.midY
            let scale = icon.width / effect.icon.width
            effect.layer.setAffineTransform(effect.transform.scaledBy(x: scale, y: scale))
        }
        effect.layer.position = CGPoint(x: effect.position.x + dx, y: effect.position.y + dy)
    }

    // MARK: - The window

    /// Puts the window over the Dock and the room just out from it, where effects spread to.
    private func open(over layout: DockLayout, style: EffectStyle) -> Painter {
        let region = Self.region(over: layout)
        let window = self.window ?? makeWindow(region)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window.frame != region {
            window.setFrame(region, display: false)
            root.frame = CGRect(origin: .zero, size: region.size)
        }
        root.opacity = 1
        CATransaction.commit()
        screen = layout.screen
        window.orderFrontRegardless()
        let scale = NSScreen.screens.first { $0.frame == layout.screen }?.backingScaleFactor ?? 2
        return Painter(edge: layout.edge, contentsScale: scale, style: style)
    }

    private func makeWindow(_ frame: CGRect) -> NSWindow {
        let window = StageWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Just above the Dock's icons.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        root.frame = view.bounds
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        self.window = window
        return window
    }

    private func show(_ effect: Effect, for duration: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(effect.layer)
        CATransaction.commit()
        effects.append(effect)
        startTracking()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.1))
            guard let self, let index = self.effects.firstIndex(where: { $0 === effect }) else { return }
            self.effects.remove(at: index)
            effect.layer.removeFromSuperlayer()
            self.closeIfIdle()
        }
    }

    private func closeIfIdle() {
        if effects.isEmpty, ambient == nil {
            window?.orderOut(nil)
            stopTracking()
        }
    }

    /// From the screen into the window.
    private func local(_ rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    private func local(_ tile: Painter.Tile) -> Painter.Tile {
        var tile = tile
        tile.icon = local(tile.icon)
        return tile
    }

    private static func region(over layout: DockLayout) -> CGRect {
        let screen = layout.screen, dock = layout.frame
        // Room for what spreads out from the Dock: sparkles, ripples, glows, which go further
        // the bigger the Dock is.
        let reach = max(200, 3.5 * min(dock.width, dock.height))
        switch layout.edge {
        case .bottom:
            return CGRect(x: screen.minX, y: screen.minY, width: screen.width,
                          height: min(screen.height, dock.maxY - screen.minY + reach))
        case .left:
            return CGRect(x: screen.minX, y: screen.minY, width: min(screen.width, dock.maxX - screen.minX + reach),
                          height: screen.height)
        case .right:
            let minX = max(screen.minX, dock.minX - reach)
            return CGRect(x: minX, y: screen.minY, width: screen.maxX - minX, height: screen.height)
        }
    }
}

/// Goes exactly where it's put, over the Dock, rather than being kept clear of it.
private final class StageWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
