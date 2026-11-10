import AppKit
import ApplicationServices

/// Which side of the screen the Dock is on.
enum DockEdge {
    case bottom
    case left
    case right
}

/// A tile in the Dock: an app, a folder, the Trash, a minimised window.
struct DockItem {
    let title: String
    /// The whole tile, in screen coordinates (from the bottom left of the main screen). It
    /// takes in the room for the dot under a running app.
    let frame: CGRect
    /// What it opens: an app, a folder or a document.
    let url: URL?
    let isApp: Bool
    let isTrash: Bool
    /// The text of its notification badge, such as a count; nil without one.
    let badge: String?
    /// To read where it is again later (`Dock.iconFrame(of:)`).
    let element: AXUIElement

    var iconFrame: CGRect { Self.iconFrame(inTile: frame) }

    /// The square the Dock draws the icon in, the Dock's icon size, in the middle of the tile.
    /// It's in proportion to the tile, so it's right at any Dock size, and for magnified icons
    /// and a Dock shrunk to fit: 45 points in a 47-point tile.
    static func iconFrame(inTile frame: CGRect) -> CGRect {
        let side = min(frame.width, frame.height) * 45 / 47
        return CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
    }
}

/// Where the Dock is.
struct DockLayout: Equatable {
    /// The Dock's bar, in screen coordinates: its glass, which the tiles fill across.
    let frame: CGRect
    let edge: DockEdge
    /// The screen it's on, or would be on while it's hidden.
    let screen: CGRect
    /// Off screen, it's hidden: it hides itself, or an app is full screen.
    let isShown: Bool
}

/// Reads the Dock through the Accessibility API: where it is, its tiles, and which one the
/// pointer is over.
@MainActor
final class Dock {
    nonisolated static let bundleID = "com.apple.dock"

    /// Whenever the pointer moves onto another tile, with that tile, or off the tiles, with nil.
    var onHover: ((DockItem?) -> Void)?

    private var process: NSRunningApplication?
    private var list: AXUIElement?
    private var observer: AXObserver?
    private var watchesHover = false
    private var restartObserver: NSObjectProtocol?
    /// Where the bar is across the list it's read from, and how thick it is (see `layout()`).
    private var barAcross: (offset: CGFloat, size: CGFloat)?

    private static let frameAttributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
    private static let itemAttributes = [kAXSubroleAttribute, kAXTitleAttribute, kAXPositionAttribute,
                                         kAXSizeAttribute, kAXURLAttribute, "AXStatusLabel"] as CFArray

    init() {
        // A Dock that stops answering shouldn't hold DockFX up for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        // The Dock restarts when some of its settings change, with a new bar to read.
        restartObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Dock.bundleID else { return }
            MainActor.assumeIsolated { self?.reconnectSoon() }
        }
    }

    private func reconnectSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.disconnect()
            _ = self?.connect()
        }
    }

    /// Where the Dock is now, or nil if it can't be read (Accessibility isn't allowed).
    func layout() -> DockLayout? {
        guard let list = connect() else { return nil }
        guard let listFrame = frame(of: list) else {
            disconnect()
            return nil
        }
        // The bar reaches as far along as the list, but across, it's where the tiles are, which
        // can be a few points off the list.
        if let first = (value(list, kAXChildrenAttribute) as? [AXUIElement])?.first, let tile = self.frame(of: first) {
            barAcross = listFrame.width >= listFrame.height
                ? (tile.minY - listFrame.minY, tile.height)
                : (tile.minX - listFrame.minX, tile.width)
        }
        let frame = bar(inList: listFrame)
        let screens = NSScreen.screens.map(\.frame)
        // Shown, it's all on one screen.
        if let screen = screens.first(where: { $0.intersection(frame).area >= frame.area * 0.9 }) {
            return DockLayout(frame: frame, edge: Self.edge(of: frame, on: screen), screen: screen, isShown: true)
        }
        // Hidden, it's just past the edge of its screen.
        let screen = screens.min { $0.distance(to: frame) < $1.distance(to: frame) } ?? .zero
        return DockLayout(frame: frame, edge: Self.edge(of: frame, on: screen), screen: screen, isShown: false)
    }

    /// Where the Dock's bar is right now: quicker than `layout()`, to follow it as it moves.
    func barFrame() -> CGRect? {
        guard let list = connect(), let frame = frame(of: list) else { return nil }
        return bar(inList: frame)
    }

    /// Where a tile's icon is right now, or nil if the tile has gone.
    func iconFrame(of tile: AXUIElement) -> CGRect? {
        frame(of: tile).map(DockItem.iconFrame(inTile:))
    }

    private func bar(inList frame: CGRect) -> CGRect {
        guard let barAcross else { return frame }
        if frame.width >= frame.height {
            return CGRect(x: frame.minX, y: frame.minY + barAcross.offset, width: frame.width, height: barAcross.size)
        }
        return CGRect(x: frame.minX + barAcross.offset, y: frame.minY, width: barAcross.size, height: frame.height)
    }

    /// The tiles, in order, without the dividers.
    func items() -> [DockItem] {
        guard let list = connect(),
              let children = value(list, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return children.compactMap(item)
    }

    /// An app's tile: the one that opens it, or else the app tile with its name.
    func item(for app: NSRunningApplication) -> DockItem? {
        let items = items()
        if let path = app.bundleURL?.resolvingSymlinksInPath().path,
           let item = items.first(where: { $0.url?.resolvingSymlinksInPath().path == path }) {
            return item
        }
        return items.first { $0.isApp && $0.title == app.localizedName }
    }

    /// Calls `onHover` as the pointer moves over the tiles.
    func watchHover(_ watch: Bool) {
        guard watch != watchesHover else { return }
        watchesHover = watch
        if watch {
            _ = connect()
            addHoverObserver()
        } else {
            removeHoverObserver()
        }
    }

    // MARK: - Reading

    private func connect() -> AXUIElement? {
        if let list, let process, !process.isTerminated { return list }
        disconnect()
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
        else { return nil }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        guard let children = value(app, kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first(where: { value($0, kAXRoleAttribute) as? String == kAXListRole })
        else { return nil }
        self.process = process
        self.list = list
        addHoverObserver()
        return list
    }

    private func disconnect() {
        removeHoverObserver()
        list = nil
        process = nil
    }

    private func hoveredItem() -> DockItem? {
        guard let list = connect(),
              let selected = value(list, kAXSelectedChildrenAttribute) as? [AXUIElement],
              let item = selected.first.flatMap(item) else { return nil }
        // Once the pointer leaves the tiles, the Dock can still report the last one for a moment.
        guard item.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return nil }
        return item
    }

    private func item(_ element: AXUIElement) -> DockItem? {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.itemAttributes, [], &result) == .success,
              let values = result as? [AnyObject], values.count == 6 else { return nil }
        let subrole = values[0] as? String
        guard subrole != "AXSeparatorDockItem",
              let position = Self.point(values[2]), let size = Self.size(values[3]), size.width > 0
        else { return nil }
        return DockItem(title: values[1] as? String ?? "",
                        frame: Self.screenRect(CGRect(origin: position, size: size)),
                        url: values[4] as? URL,
                        isApp: subrole == "AXApplicationDockItem",
                        isTrash: subrole == "AXTrashDockItem",
                        badge: (values[5] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        element: element)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.frameAttributes, [], &result) == .success,
              let values = result as? [AnyObject], values.count == 2,
              let position = Self.point(values[0]), let size = Self.size(values[1]) else { return nil }
        return Self.screenRect(CGRect(origin: position, size: size))
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Accessibility counts down from the top left of the main screen; AppKit up from its
    /// bottom left.
    private static func screenRect(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func edge(of frame: CGRect, on screen: CGRect) -> DockEdge {
        if frame.width >= frame.height { return .bottom }
        return frame.midX < screen.midX ? .left : .right
    }

    // MARK: - Hover

    private func addHoverObserver() {
        guard watchesHover, observer == nil, let process, let list else { return }
        var observer: AXObserver?
        guard AXObserverCreate(process.processIdentifier, { _, _, _, refcon in
            guard let refcon else { return }
            let dock = Unmanaged<Dock>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { dock.onHover?(dock.hoveredItem()) }
        }, &observer) == .success, let observer else { return }
        AXObserverAddNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        // Common modes, so it plays while a menu is open too.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer
    }

    private func removeHoverObserver() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    /// How far apart two rectangles are; 0 if they touch.
    func distance(to other: CGRect) -> CGFloat {
        let dx = max(0, max(minX - other.maxX, other.minX - maxX))
        let dy = max(0, max(minY - other.maxY, other.minY - maxY))
        return (dx * dx + dy * dy).squareRoot()
    }
}
