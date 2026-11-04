import AppKit
import ApplicationServices
import Observation

/// DockFX needs one permission: Accessibility, to find where each icon is in the Dock and
/// which one the pointer is over.
@Observable @MainActor
final class Permissions {
    private(set) var accessibility = AXIsProcessTrusted()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?

    func refresh() {
        let accessibility = AXIsProcessTrusted()
        guard accessibility != self.accessibility else { return }
        self.accessibility = accessibility
        onChange?()
    }

    /// Checks every second while it's missing, so the effects start the moment it's allowed.
    func watchUntilGranted() {
        guard timer == nil, !accessibility else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if self.accessibility {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
    }

    /// Shows macOS's own prompt, which also puts DockFX in the list in System Settings, where
    /// it can be switched on. On first launch.
    func promptForAccessibility() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        watchUntilGranted()
    }

    /// Opens Privacy & Security › Accessibility in System Settings.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        watchUntilGranted()
    }
}
