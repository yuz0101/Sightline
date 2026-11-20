import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?

    /// The window's "Arrange now" button calls back into the app delegate.
    private let onArrange: (() -> Void)?

    init(prefs: Preferences, displays: DisplayRegistry, onArrange: (() -> Void)? = nil) {
        self.model = SettingsModel(prefs: prefs, displays: displays)
        self.onArrange = onArrange
    }

    func reload() {
        model.reload()
    }

    func refreshTrust() {
        model.refreshTrust()
    }

    func setUnavailableShortcuts(_ actions: [HotKeyAction]) {
        model.setUnavailable(actions)
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(model: model, onArrange: onArrange))
            // The whole page fits on a 5K display: scrolling inside the
            // window is only a fallback for shorter screens, and a scroll view
            // that overflows its window stops hit-testing reliably.
            let maxContent = (NSScreen.main?.visibleFrame.height ?? 900) - 40
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: min(1306, maxContent)),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sightline"
            window.contentView = hosting
            window.minSize = NSSize(width: 780, height: 620)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("SightlineSettings")
            self.window = window
        }
        model.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
