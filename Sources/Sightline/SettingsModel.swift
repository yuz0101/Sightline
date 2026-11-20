import SwiftUI
import SightlineCore

/// Model backing the settings window. Editing a control writes straight through
/// to preferences, which reflows every tracked window immediately.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var centerFraction: Double = 0.55 { didSet { commitLayout() } }
    @Published var splitSides: Bool = true { didSet { commitLayout() } }
    @Published var viewingDistanceCM: Double = 65 { didSet { commitLayout() } }
    @Published var avoidDock: Bool = true { didSet { commitEnvironment() } }
    @Published var dragSnapEnabled: Bool = true { didSet { commitEnvironment() } }
    @Published var quickMenuEnabled: Bool = true { didSet { commitEnvironment() } }
    @Published var quickMenuOnDesktopRightClick: Bool = true { didSet { commitEnvironment() } }

    @Published private(set) var screen: ScreenInfo?
    @Published private(set) var trusted: Bool = Accessibility.isTrusted
    @Published private(set) var unavailable: [HotKeyAction] = []

    private let prefs: Preferences
    private let displays: DisplayRegistry
    private var syncing = false

    init(prefs: Preferences, displays: DisplayRegistry) {
        self.prefs = prefs
        self.displays = displays
        reload()
    }

    func reload() {
        syncing = true
        let currentID = screen?.id ?? ""
        screen = displays.screen(id: currentID) ?? displays.primary
        let layout = screen.map { prefs.layout(for: $0.id) } ?? prefs.defaultLayout
        centerFraction = layout.centerFraction
        splitSides = layout.splitSides
        viewingDistanceCM = layout.viewingDistanceCM
        avoidDock = prefs.avoidDock
        dragSnapEnabled = prefs.dragSnapEnabled
        quickMenuEnabled = prefs.quickMenuEnabled
        quickMenuOnDesktopRightClick = prefs.quickMenuOnDesktopRightClick
        trusted = Accessibility.isTrusted
        syncing = false
    }

    func refreshTrust() {
        trusted = Accessibility.isTrusted
    }

    func setUnavailable(_ actions: [HotKeyAction]) {
        unavailable = actions
    }

    var layout: ScreenLayout {
        ScreenLayout(
            centerFraction: centerFraction,
            splitSides: splitSides,
            gap: 0,
            outerMargin: 0,
            viewingDistanceCM: viewingDistanceCM
        )
    }

    var geometry: LayoutGeometry? {
        guard let screen else { return nil }
        return LayoutGeometry(frame: screen.usableFrame, layout: layout)
    }

    var metrics: AttentionMetrics? {
        guard let screen, let geometry else { return nil }
        return AttentionMetrics(
            frame: screen.usableFrame,
            layout: layout,
            geometry: geometry,
            physicalWidthCM: screen.physicalWidthCM
        )
    }

    /// Half-angle the centre board would subtend with `fraction` on the current
    /// display, used to label presets that fall outside the comfort band.
    func halfAngle(forCenterFraction fraction: Double) -> Double? {
        guard let screen else { return nil }
        var layout = self.layout
        layout.centerFraction = fraction
        let geometry = screen.geometry(layout)
        return AttentionMetrics(
            frame: screen.usableFrame,
            layout: layout,
            geometry: geometry,
            physicalWidthCM: screen.physicalWidthCM
        ).centerHalfAngleDeg
    }

    func apply(preset: LayoutPreset) {
        centerFraction = preset.centerFraction
    }

    func applyToAllDisplays() {
        var layout = self.layout
        layout.centerFraction = centerFraction
        prefs.setDefaultLayout(layout)
    }

    var preferencesPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sightline", isDirectory: true).path
    }

    private func commitLayout() {
        guard !syncing, let screen else { return }
        var updated = prefs.layout(for: screen.id)
        updated.centerFraction = (centerFraction * 1000).rounded() / 1000
        updated.splitSides = splitSides
        updated.viewingDistanceCM = viewingDistanceCM
        prefs.setLayout(updated, for: screen.id)
    }

    private func commitEnvironment() {
        guard !syncing else { return }
        prefs.setEnvironment(
            avoidDock: avoidDock,
            dragSnapEnabled: dragSnapEnabled,
            quickMenuEnabled: quickMenuEnabled,
            quickMenuOnDesktopRightClick: quickMenuOnDesktopRightClick
        )
    }
}
