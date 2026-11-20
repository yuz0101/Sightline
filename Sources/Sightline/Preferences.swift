import Foundation
import SightlineCore

/// Persisted, observable settings. Everything is written atomically on change;
/// the file lives in Application Support so it survives rebuilds.
@MainActor
final class Preferences {
    static let shared = Preferences()

    struct Store: Codable, Equatable {
        var layout = ScreenLayout.defaultLayout
        var displayOverrides: [String: ScreenLayout] = [:]
        var avoidDock = true
        var hasSeenOnboarding = false
        var dragSnapEnabled = true
        /// Option-right-click opens a compact Sightline menu.
        var quickMenuEnabled = true
        var quickMenuOnDesktopRightClick = true
        /// Where each app sat last time, per display: displayID → bundleID → slot.
        /// Arrange uses it as a hint so a familiar app lands where you left it.
        var boardMemory: [String: [String: String]] = [:]

        init() {}

        // Decode leniently: a preferences file written by an older build must not
        // wipe the user's layouts just because a key is missing.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            layout = try container.decodeIfPresent(ScreenLayout.self, forKey: .layout) ?? .defaultLayout
            displayOverrides = try container.decodeIfPresent([String: ScreenLayout].self, forKey: .displayOverrides) ?? [:]
            avoidDock = try container.decodeIfPresent(Bool.self, forKey: .avoidDock) ?? true
            hasSeenOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? false
            dragSnapEnabled = try container.decodeIfPresent(Bool.self, forKey: .dragSnapEnabled) ?? true
            quickMenuEnabled = try container.decodeIfPresent(Bool.self, forKey: .quickMenuEnabled) ?? true
            quickMenuOnDesktopRightClick = try container.decodeIfPresent(Bool.self, forKey: .quickMenuOnDesktopRightClick) ?? true
            boardMemory = try container.decodeIfPresent([String: [String: String]].self, forKey: .boardMemory) ?? [:]
        }
    }

    private(set) var store = Store()
    private var loaded = false
    var onChange: ((_ changedDisplay: String?) -> Void)?

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sightline", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    /// The app used to be called ScreenBoard. Adopt its preferences once so the
    /// rename does not cost the user their layouts, board memory or toggles.
    private var legacyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ScreenBoard", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        var data = try? Data(contentsOf: fileURL)
        if data == nil, let legacy = try? Data(contentsOf: legacyFileURL) {
            data = legacy
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? legacy.write(to: fileURL, options: .atomic)
        }
        guard let data,
              let decoded = try? JSONDecoder().decode(Store.self, from: data) else { return }
        store = decoded
        // Boards abut: force any gutter persisted by an older build to zero.
        var normalised = decoded
        normalised.layout.gap = 0
        for (id, var override) in normalised.displayOverrides {
            override.gap = 0
            normalised.displayOverrides[id] = override
        }
        if normalised != decoded {
            store = normalised
            save()
        }
    }

    func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(store)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            if ProcessInfo.processInfo.environment["SIGHTLINE_VERBOSE"] != nil {
                log("memory: save failed: \(error)")
            }
        }
    }

    // MARK: Layout access

    func layout(for displayID: String) -> ScreenLayout {
        store.displayOverrides[displayID] ?? store.layout
    }

    /// The layout used when no display is known (menu presets, defaults).
    var defaultLayout: ScreenLayout { store.layout }

    func setDefaultLayout(_ layout: ScreenLayout) {
        store.layout = layout
        store.displayOverrides.removeAll()
        save()
        onChange?(nil)
    }

    func setLayout(_ layout: ScreenLayout, for displayID: String) {
        store.displayOverrides[displayID] = layout
        save()
        onChange?(displayID)
    }

    /// `delta` is in percentage points: +1 widens the centre board by one point.
    func nudgeCenterFraction(by delta: Double, displayID: String) {
        var l = layout(for: displayID)
        let percent = (l.centerFraction * 100).rounded() + delta
        l.centerFraction = min(70, max(40, percent)) / 100
        setLayout(l, for: displayID)
    }

    var dragSnapEnabled: Bool {
        get { store.dragSnapEnabled }
        set {
            guard store.dragSnapEnabled != newValue else { return }
            store.dragSnapEnabled = newValue
            save()
            onChange?(nil)
        }
    }

    /// Plain right-click on the wallpaper opens the Sightline menu instead of
    /// Finder's. Off restores Finder's own desktop menu.
    var quickMenuOnDesktopRightClick: Bool {
        get { store.quickMenuOnDesktopRightClick }
        set {
            guard store.quickMenuOnDesktopRightClick != newValue else { return }
            store.quickMenuOnDesktopRightClick = newValue
            save()
            onChange?(nil)
        }
    }

    /// Writes the environment switches in one pass. Writing them one setter at
    /// a time fires `onChange` per property, and the observer reloads the
    /// settings model from disk mid-commit, which reverts a toggle the user
    /// just flipped. One save, one notification.
    func setEnvironment(avoidDock: Bool,
                        dragSnapEnabled: Bool,
                        quickMenuEnabled: Bool,
                        quickMenuOnDesktopRightClick: Bool) {
        var changed = false
        if store.avoidDock != avoidDock { store.avoidDock = avoidDock; changed = true }
        if store.dragSnapEnabled != dragSnapEnabled { store.dragSnapEnabled = dragSnapEnabled; changed = true }
        if store.quickMenuEnabled != quickMenuEnabled { store.quickMenuEnabled = quickMenuEnabled; changed = true }
        if store.quickMenuOnDesktopRightClick != quickMenuOnDesktopRightClick {
            store.quickMenuOnDesktopRightClick = quickMenuOnDesktopRightClick
            changed = true
        }
        guard changed else { return }
        save()
        onChange?(nil)
    }

    var quickMenuEnabled: Bool {
        get { store.quickMenuEnabled }
        set {
            guard store.quickMenuEnabled != newValue else { return }
            store.quickMenuEnabled = newValue
            save()
            onChange?(nil)
        }
    }

    func toggleSplit(displayID: String) {
        var l = layout(for: displayID)
        l.splitSides.toggle()
        setLayout(l, for: displayID)
    }

    var avoidDock: Bool {
        get { store.avoidDock }
        set {
            store.avoidDock = newValue
            save()
            onChange?(nil)
        }
    }

    var hasSeenOnboarding: Bool {
        get { store.hasSeenOnboarding }
        set {
            store.hasSeenOnboarding = newValue
            save()
        }
    }

    // MARK: Board memory

    /// Where this app sat the last time Sightline placed it on this display.
    func rememberedSlot(forBundleID bundleID: String, displayID: String) -> Slot? {
        guard let raw = store.boardMemory[displayID]?[bundleID] else { return nil }
        return Slot(rawValue: raw)
    }

    /// Remember a placement. Only the app's identity is stored — never its
    /// contents — so the memory survives window close/reopen and app restarts.
    func remember(_ slot: Slot, bundleID: String?, displayID: String) {
        if ProcessInfo.processInfo.environment["SIGHTLINE_VERBOSE"] != nil {
            log("memory: remember \(bundleID ?? "nil") -> \(slot.rawValue) on \(displayID)")
        }
        guard let bundleID, !bundleID.isEmpty else { return }
        var memory = store.boardMemory[displayID] ?? [:]
        guard memory[bundleID] != slot.rawValue else { return }
        memory[bundleID] = slot.rawValue
        store.boardMemory[displayID] = memory
        save()
    }

    /// All remembered app → board assignments for one display.
    func boardMemory(for displayID: String) -> [String: Slot] {
        (store.boardMemory[displayID] ?? [:]).compactMapValues(Slot.init(rawValue:))
    }

    var hasBoardMemory: Bool { store.boardMemory.contains { !$0.value.isEmpty } }

    var boardMemoryCount: Int { store.boardMemory.values.reduce(0) { $0 + $1.count } }

    func forgetBoardMemory() {
        guard hasBoardMemory else { return }
        store.boardMemory.removeAll()
        save()
    }
}

extension Preferences {
    fileprivate func log(_ line: String) {
        FileHandle.standardError.write("Sightline: \(line)\n".data(using: .utf8)!)
    }
}
