import AppKit
import AppShell

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private let permissions = Permissions()
    private lazy var watcher = DockWatcher(prefs: prefs)
    private lazy var menuBar: MenuBar = MenuBar(symbol: "sparkles", items: { [weak self] menu in
        self?.addMenuItems(to: menu)
    }, showSettings: { [weak self] in
        self?.settings.show()
    })
    /// General, where Accessibility is allowed.
    private static let generalTab = 0
    private lazy var settings: SettingsWindow = {
        let window = SettingsWindow { [weak self] in
            guard let self else { return [] }
            // General, a tab for each moment, then About.
            return [.general(menuBar: menuBar) { GeneralSettings(prefs: self.prefs, permissions: self.permissions) }]
                + Moment.allCases.map { moment in
                    SettingsTab(moment.title, symbol: moment.symbol) {
                        MomentSettings(prefs: self.prefs, moment: moment, permissions: self.permissions) {
                            self.watcher.tryIt(moment)
                        }
                    }
                }
                + [.about()]
        }
        window.onBecameKey = { [weak self] in self?.permissions.refresh() }
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The permission given to the temporary copy macOS runs from Downloads doesn't stick.
        if AppShell.quitIfTranslocated(problem: "and the permission DockFX needs wouldn't stick to it") { return }
        prefs.onEnabledChange = { [weak self] in self?.update() }
        prefs.onStylesChange = { [weak self] in self?.update() }
        permissions.onChange = { [weak self] in self?.update() }
        menuBar.install()
        update()
        if !permissions.accessibility {
            permissions.promptForAccessibility()
            showGeneral()
        }
    }

    /// Opening DockFX again (Finder, Spotlight) shows Settings, which matters when the menu
    /// bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    private func update() {
        menuBar.appearsDisabled = !prefs.isEnabled || !permissions.accessibility
        watcher.update(allowed: permissions.accessibility)
    }

    private func showGeneral() {
        settings.show()
        settings.selectTab(Self.generalTab)
    }

    /// DockFX's items in the menu bar menu; AppShell adds Settings… and Quit.
    private func addMenuItems(to menu: NSMenu) {
        permissions.refresh()
        if !permissions.accessibility {
            let warning = NSMenuItem("Allow Accessibility…") { [weak self] in
                self?.showGeneral()
            }
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem("Turn On DockFX", isOn: prefs.isEnabled) { [weak self] in
            self?.prefs.isEnabled.toggle()
        })
        let tryItem = NSMenuItem(title: "Try a Look", action: nil, keyEquivalent: "")
        let looks = NSMenu()
        for look in Look.visible {
            looks.addItem(NSMenuItem(look.label) { [weak self] in
                // Once the menu has closed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.watcher.tryLook(look)
                }
            })
        }
        tryItem.submenu = looks
        tryItem.isEnabled = permissions.accessibility
        menu.addItem(tryItem)
    }
}
