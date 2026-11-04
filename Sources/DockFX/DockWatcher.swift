import AppKit

/// Plays the effects (Preferences) at the right moments: the pointer moving onto an icon, an
/// app opening, switching apps, the Dock sliding in, and all the while the Dock shows.
@MainActor
final class DockWatcher {
    private let prefs: Preferences
    private let dock: Dock
    private let stage: Stage
    private var isRunning = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pointerMonitor: Any?
    /// The Dock as last read.
    private var layout: DockLayout?
    private var pointerOverDock = false
    private var waitingForDock = false
    private var hideCheck: Task<Void, Never>?
    private var layoutCheck: Task<Void, Never>?
    private var hovered: DockItem?
    /// When each app opened, so switching to it as it opens doesn't play a second effect.
    private var openedAt: [pid_t: Date] = [:]

    init(prefs: Preferences) {
        self.prefs = prefs
        dock = Dock()
        stage = Stage(dock: dock)
        dock.onHover = { [weak self] item in self?.hover(item) }
        stage.onDockHidden = { [weak self] in self?.refreshLayout() }
    }

    /// Starts, stops or changes what DockFX watches, for the settings and whether
    /// Accessibility is `allowed`.
    func update(allowed: Bool) {
        let run = allowed && prefs.isEnabled
        if run != isRunning {
            run ? start() : stop()
        }
        guard run else { return }
        dock.watchHover(prefs[.pointing].look != .off)
        // Only to notice the Dock sliding in and out, for those two moments.
        let followsPointer = prefs[.slidingIn].look != .off || prefs[.always].look != .off
        if followsPointer, pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved(NSEvent.mouseLocation) }
            }
        } else if !followsPointer, let monitor = pointerMonitor {
            NSEvent.removeMonitor(monitor)
            pointerMonitor = nil
        }
        refreshLayout()
    }

    /// Plays a moment's effect as it's set now: on every icon in turn, or along the Dock. A beep
    /// if the Dock is hidden.
    func tryIt(_ moment: Moment) {
        play(prefs[moment], along: !moment.isOnIcon)
    }

    /// Plays `look`, with its normal settings, on every icon in turn.
    func tryLook(_ look: Look) {
        play(EffectStyle(look: look), along: false)
    }

    private func play(_ style: EffectStyle, along: Bool) {
        guard style.look != .off else { return }
        guard let layout = dock.layout(), layout.isShown else {
            NSSound.beep()
            return
        }
        let tiles = dock.items().map { tile($0, style) }
        if along {
            stage.playAlong(style, tiles: tiles, tint: tint(style), over: layout)
        } else {
            stage.play(style, on: tiles, stagger: 0.07, density: 0.6, over: layout)
        }
    }

    // MARK: - Starting and stopping

    private func start() {
        isRunning = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] pid in self?.opened(pid) }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] pid in self?.switched(to: pid) }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] pid in
            self?.openedAt[pid] = nil
            self?.checkLayoutSoon()
        }
        // Into or out of a full-screen app, the Dock hides or comes back.
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.stage.follow(for: 2)
            self?.checkLayoutSoon()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.checkLayoutSoon() }
    }

    private func stop() {
        isRunning = false
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers = []
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
        dock.watchHover(false)
        hideCheck?.cancel()
        layoutCheck?.cancel()
        stage.hideAmbient()
    }

    /// Calls `handler` with the app's process ID, or 0 for notifications without an app.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (pid_t) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier ?? 0
            MainActor.assumeIsolated { handler(pid) }
        }
        observers.append((center, observer))
    }

    // MARK: - The moments

    private func hover(_ item: DockItem?) {
        guard let item else {
            hovered = nil
            return
        }
        // The same tile can move under the pointer, with magnification on.
        guard item.title != hovered?.title || item.url != hovered?.url else { return }
        hovered = item
        let style = prefs[.pointing]
        guard style.look != .off, let layout = dock.layout(), layout.isShown else { return }
        stage.play(style, on: [tile(item, style)], over: layout)
    }

    private func opened(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return }
        openedAt[pid] = Date()
        playOnApp(pid, .opening, tries: 6)
        checkLayoutSoon()
    }

    private func switched(to pid: pid_t) {
        guard pid != getpid(), prefs[.switching].look != .off,
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return }
        // An app that's opening gets the opening effect instead.
        if prefs[.opening].look != .off {
            if !app.isFinishedLaunching { return }
            if let opened = openedAt[pid], Date().timeIntervalSince(opened) < 3 { return }
        }
        playOnApp(pid, .switching, tries: 2)
    }

    /// Plays a moment's effect on an app's icon, trying a few times while a new tile appears in
    /// the Dock.
    private func playOnApp(_ pid: pid_t, _ moment: Moment, tries: Int) {
        let style = prefs[moment]
        guard style.look != .off, let app = NSRunningApplication(processIdentifier: pid),
              let layout = dock.layout(), layout.isShown else { return }
        guard let item = dock.item(for: app) else {
            guard tries > 1 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.playOnApp(pid, moment, tries: tries - 1)
            }
            return
        }
        stage.play(style, on: [tile(item, style)], over: layout)
    }

    // MARK: - The Dock sliding in and out

    private func pointerMoved(_ point: CGPoint) {
        guard let layout else { return }
        if !layout.isShown {
            if !waitingForDock, Self.isAtEdge(point, layout.edge) {
                waitForDock()
            }
            return
        }
        let over = Self.reach(of: layout).contains(point)
        if pointerOverDock, !over {
            // If the Dock hides itself, all the time effect goes with it.
            stage.follow(for: 4)
            checkHiddenSoon()
        }
        pointerOverDock = over
    }

    /// The pointer is at the edge of the screen: the Dock comes in once it has been pushed
    /// there a moment, and takes a fifth of a second to slide in.
    private func waitForDock() {
        waitingForDock = true
        Task { @MainActor [weak self] in
            var last: CGRect?
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, let layout = self.dock.layout() else { return }
                // Plays once it has stopped moving.
                if layout.isShown, layout.frame == last {
                    self.waitingForDock = false
                    self.slidIn(layout)
                    return
                }
                last = layout.frame
            }
            self?.waitingForDock = false
        }
    }

    private func slidIn(_ layout: DockLayout) {
        self.layout = layout
        pointerOverDock = true
        let style = prefs[.slidingIn]
        if style.look != .off {
            let tiles = dock.items().map { tile($0, style) }
            stage.playAlong(style, tiles: tiles, tint: tint(style), over: layout)
        }
        updateAmbient()
    }

    /// The pointer left the Dock: if it hides itself, it's gone a moment later.
    private func checkHiddenSoon() {
        hideCheck?.cancel()
        hideCheck = Task { @MainActor [weak self] in
            for wait in [1.0, 1.5, 2.5] {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, !self.pointerOverDock else { return }
                self.refreshLayout()
                if self.layout?.isShown == false { return }
            }
        }
    }

    /// After apps open and quit, the Dock grows or shrinks once its tiles have moved.
    private func checkLayoutSoon() {
        layoutCheck?.cancel()
        layoutCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.pointerOverDock = false
            self?.refreshLayout()
        }
    }

    private func refreshLayout() {
        layout = dock.layout()
        updateAmbient()
    }

    private func updateAmbient() {
        let style = prefs[.always]
        guard isRunning, style.look != .off, let layout, layout.isShown else {
            stage.hideAmbient()
            return
        }
        let tiles = dock.items().map { tile($0, style) }
        stage.showAmbient(style, tiles: tiles, tint: tint(style), over: layout)
    }

    private static func isAtEdge(_ point: CGPoint, _ edge: DockEdge) -> Bool {
        NSScreen.screens.contains { screen in
            let frame = screen.frame
            switch edge {
            case .bottom: return point.y < frame.minY + 2 && point.x >= frame.minX && point.x <= frame.maxX
            case .left: return point.x < frame.minX + 2 && point.y >= frame.minY && point.y <= frame.maxY
            case .right: return point.x > frame.maxX - 2 && point.y >= frame.minY && point.y <= frame.maxY
            }
        }
    }

    /// Where the pointer keeps the Dock in: over it, and between it and the edge.
    private static func reach(of layout: DockLayout) -> CGRect {
        let dock = layout.frame.insetBy(dx: -8, dy: -8), screen = layout.screen
        switch layout.edge {
        case .bottom: return CGRect(x: dock.minX, y: screen.minY, width: dock.width, height: dock.maxY - screen.minY)
        case .left: return CGRect(x: screen.minX, y: dock.minY, width: dock.maxX - screen.minX, height: dock.height)
        case .right: return CGRect(x: dock.minX, y: dock.minY, width: screen.maxX - dock.minX, height: dock.height)
        }
    }

    // MARK: - Colours

    private func tile(_ item: DockItem, _ style: EffectStyle) -> Painter.Tile {
        let color: CGColor = switch style.color {
        case .icon: IconColors.color(for: item)
        case .accent: NSColor.controlAccentColor.cgColor
        case .white: .white
        case .custom: .hex(style.customColor)
        }
        return Painter.Tile(icon: item.iconFrame, color: color, element: item.element,
                            picture: IconColors.picture(for: item), isApp: item.isApp)
    }

    /// For effects along the whole Dock that take one colour: white, unless one is chosen.
    private func tint(_ style: EffectStyle) -> CGColor {
        switch style.color {
        case .icon, .white: .white
        case .accent: NSColor.controlAccentColor.cgColor
        case .custom: .hex(style.customColor)
        }
    }
}
