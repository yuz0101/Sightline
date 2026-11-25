import AppKit
import SightlineCore

enum HopDirection {
    case left, right, up, down
}

struct Placement: Equatable {
    var displayID: String
    var slot: Slot
}

struct ArrangementEntry: Codable {
    var bundleID: String?
    var appName: String
    var title: String
    var slot: Slot
    var displayID: String
}

struct Arrangement: Codable {
    var savedAt: Date
    var entries: [ArrangementEntry]
}

/// Owns the mapping between windows and layout slots, and every verb that
/// changes it. All AX work happens on the main actor.
@MainActor
final class SnapController {
    private let driver: WindowDriver
    private let displays: DisplayRegistry
    private let prefs: Preferences

    /// Which slot each window is believed to occupy. Entries self-heal: a window
    /// whose frame no longer matches its slot is treated as floating.
    private var assignments: [WindowKey: Placement] = [:]
    /// Rotating queue of the windows that belong on the centre stage, front first.
    private var stages: [String: [WindowKey]] = [:]

    private let swapOverlay = BoardOverlay()
    private struct SwapPreview {
        let screen: ScreenInfo
        let geometry: LayoutGeometry
        let windows: [Slot: VisibleWindow]
        var slot: Slot?
    }
    private var swapPreview: SwapPreview?

    var onStatus: ((String, CGRect?) -> Void)?

    init(driver: WindowDriver, displays: DisplayRegistry, prefs: Preferences) {
        self.driver = driver
        self.displays = displays
        self.prefs = prefs
    }

    // MARK: - Layout helpers

    func layout(for screen: ScreenInfo) -> ScreenLayout { prefs.layout(for: screen.id) }
    func geometry(for screen: ScreenInfo) -> LayoutGeometry { screen.geometry(layout(for: screen)) }

    /// macOS refuses to make a window that would fill the usable height flush with
    /// the bottom edge: it clamps the height one point short. So the boards stop one
    /// point above that edge too, which keeps the centre board and the two side
    /// columns ending on the same line instead of a stepped bottom.
    private func boardRect(_ rect: CGRect, on screen: ScreenInfo) -> CGRect {
        let limit = screen.usableFrame.maxY - 1
        guard rect.maxY > limit else { return rect }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                      height: max(1, rect.height - (rect.maxY - limit)))
    }

    // MARK: - Placement

    func placeFocused(in slot: Slot) {
        guard let window = driver.focusedWindow() else {
            report("No window is focused")
            return
        }
        guard let frame = driver.frame(of: window.element),
              let screen = displays.screen(for: frame) else {
            report("Couldn't determine the screen")
            return
        }
        perform(window: window, slot: slot, screen: screen)
    }

    @discardableResult
    func perform(window: AXWindow, slot: Slot, screen: ScreenInfo,
                 updateStage: Bool = true, swapFrom: Slot? = nil) -> Bool {
        let geo = geometry(for: screen)
        guard let raw = geo.rect(for: slot) else { return false }
        let target = boardRect(raw, on: screen)
        let canonical = geo.canonical(slot)

        guard driver.isSettable(window.element, kAXPositionAttribute) else {
            report("\(window.appName) doesn't let Sightline move this window")
            return false
        }

        // Capture the destination before the dragged window covers it. Resizing
        // the window under the pointer comes first, even if its neighbour is slow.
        // WindowServer can be one frame behind a just-completed placement.
        // Include its visible window ID and check its live AX frame below.
        let tracked = assignments.compactMap { key, placement -> VisibleWindow? in
            guard placement.displayID == screen.id, geo.canonical(placement.slot) == canonical,
                  let number = key.number else { return nil }
            return VisibleWindow(pid: key.pid, number: number)
        }
        let candidates = driver.visibleWindows().filter { candidate in
            guard candidate.window.pid != window.key.pid || candidate.window.number != window.key.number else { return false }
            return WindowDriver.matches(candidate.frame, raw, tolerance: 8) || tracked.contains(candidate.window)
        }
        let previous = assignments[window.key].flatMap { $0.displayID == screen.id ? $0.slot : nil }
        let source = (swapFrom ?? previous).map(geo.canonical)
        let oldFrame = candidates.isEmpty ? nil : driver.frame(of: window.element)

        driver.ensureVisible(window)
        guard driver.setFrame(target, of: window.element) else {
            if let oldFrame { driver.setFrame(oldFrame, of: window.element) }
            report("Couldn't resize \(window.appName) to fit")
            return false
        }

        for candidate in candidates {
            guard let occupant = driver.resolve(candidate.window, in: raw, excluding: window) else { continue }
            if let source, source != canonical, let sourceRect = geo.rect(for: source),
               driver.setFrame(boardRect(sourceRect, on: screen), of: occupant.element) {
                remember(occupant, in: source, on: screen)
            } else if source == nil || source == canonical, let oldFrame,
                      driver.setFrame(Self.clamp(oldFrame, into: screen.frame), of: occupant.element) {
                assignments[occupant.key] = nil
            } else {
                assignments[occupant.key] = nil
                pushStage(occupant.key, displayID: screen.id)
            }
            break
        }

        // A closed or manually moved window may still claim this board. Once
        // filled, it must not pull a stale occupant back on the next reflow.
        assignments = assignments.filter { _, placement in
            placement.displayID != screen.id || geo.canonical(placement.slot) != canonical
        }
        finishPlacement(window, in: slot, on: screen, target: target, updateStage: updateStage)
        return true
    }

    private func remember(_ window: AXWindow, in slot: Slot, on screen: ScreenInfo) {
        assignments[window.key] = Placement(displayID: screen.id, slot: slot)
        prefs.remember(slot, bundleID: window.bundleID, displayID: screen.id)
    }

    private func finishPlacement(_ window: AXWindow, in slot: Slot, on screen: ScreenInfo,
                                 target: CGRect, updateStage: Bool = true) {
        remember(window, in: slot, on: screen)
        if slot == .center && updateStage { pushStage(window.key, displayID: screen.id) }
        driver.focus(window)
        report("\(slot.label) · \(shortTitle(window))", over: target)
    }

    func handleCentreSwap(_ update: CentreSwapUpdate) {
        switch update {
        case .preview(let selection):
            if swapPreview == nil, let screen = activeScreen() {
                let geometry = geometry(for: screen)
                swapPreview = SwapPreview(screen: screen, geometry: geometry, windows: driver.visibleOccupants(of: geometry))
            }
            guard var preview = swapPreview else { return }
            preview.slot = selection.slot(among: Set(preview.windows.keys))
            swapPreview = preview
            if let slot = preview.slot {
                swapOverlay.show(screen: preview.screen, boards: preview.geometry.boards, highlight: slot)
            } else {
                swapOverlay.hide()
            }
        case .commit, .cancel:
            let preview = swapPreview
            swapPreview = nil
            swapOverlay.hide()
            if update == .commit, let preview, let slot = preview.slot {
                commitCentreSwap(preview, from: slot)
            }
        }
    }

    private func commitCentreSwap(_ preview: SwapPreview, from slot: Slot) {
        // A Space change, a closed window or a layout edit while holding the
        // chord must never exchange a different pair from the one previewed.
        guard let screen = displays.screen(id: preview.screen.id) else { return }
        let geometry = geometry(for: screen)
        guard geometry.rects == preview.geometry.rects,
              let sideRect = geometry.rect(for: slot), let centreRect = geometry.rect(for: .center),
              let source = preview.windows[slot] else { return }
        let current = driver.visibleOccupants(of: geometry)
        guard current[slot] == source, current[.center] == preview.windows[.center],
              let incoming = driver.resolve(source, in: sideRect),
              let oldSide = driver.frame(of: incoming.element) else { return }

        let centreTarget = boardRect(centreRect, on: screen)
        let sideTarget = boardRect(sideRect, on: screen)
        var displaced: (window: AXWindow, frame: CGRect)?
        if let visible = current[.center] {
            guard let window = driver.resolve(visible, in: centreRect),
                  let original = driver.frame(of: window.element) else { return }
            guard driver.setFrame(sideTarget, of: window.element) else {
                driver.setFrame(original, of: window.element)
                report("Couldn’t fit \(window.appName) in the side pane", over: sideTarget)
                return
            }
            displaced = (window, original)
        }
        guard driver.setFrame(centreTarget, of: incoming.element) else {
            driver.setFrame(oldSide, of: incoming.element)
            if let displaced { driver.setFrame(displaced.frame, of: displaced.window.element) }
            report("Couldn’t fit \(incoming.appName) in the centre pane", over: centreTarget)
            return
        }
        if let displaced { remember(displaced.window, in: slot, on: screen) }
        finishPlacement(incoming, in: .center, on: screen, target: centreTarget)
    }

    // MARK: - One-click arrange

    /// Order in which empty boards are filled. Symmetric: centre first, then the
    /// tops, then the bottoms, so a two- or three-window arrange stays balanced.
    static let arrangeOrder: [Slot] = [.center, .leftTop, .rightTop, .leftBottom, .rightBottom]

    /// Fill the boards of a display with the windows that already live on it.
    /// This rebuilds the assignment rather than moving windows one by one, so a
    /// window can never be displaced by a cascade: whoever lands in a board takes
    /// it, and windows beyond the fifth board stay where they are.
    @discardableResult
    func arrangeAll(on explicitScreen: ScreenInfo? = nil) -> Int {
        let focused = driver.focusedWindow()
        let target = explicitScreen
            ?? focused.flatMap { window in
                driver.frame(of: window.element).flatMap { displays.screen(for: $0) }
            }
            ?? displays.primary
        guard let target else {
            report("Couldn't determine the screen")
            return 0
        }
        let usable = target.usableFrame

        var seen = Set<WindowKey>()
        var candidates: [AXWindow] = []
        for window in driver.allWindows() {
            guard window.key.pid != getpid(),
                  !seen.contains(window.key),
                  !driver.isMinimized(window),
                  let frame = driver.frame(of: window.element),
                  frame.width >= 120, frame.height >= 80,
                  frame.intersects(usable),
                  driver.isSettable(window.element, kAXPositionAttribute),
                  driver.isSettable(window.element, kAXSizeAttribute)
            else { continue }
            seen.insert(window.key)
            candidates.append(window)
        }
        if ProcessInfo.processInfo.environment["SIGHTLINE_VERBOSE"] != nil {
            let line = "arrange: \(candidates.count) window(s) on \(target.name)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        guard !candidates.isEmpty else {
            report("No windows to arrange")
            return 0
        }

        // The window you are working in gets the centre board; the planner then
        // prefers apps that remember a board, and falls back to the biggest window.
        let memory = prefs.boardMemory(for: target.id)
        var byKey: [String: AXWindow] = [:]
        var plannerInput: [ArrangeCandidate] = []
        for (index, window) in candidates.enumerated() {
            let key = String(index)
            byKey[key] = window
            let size = driver.frame(of: window.element)?.size ?? .zero
            plannerInput.append(ArrangeCandidate(
                key: key,
                bundleID: window.bundleID ?? "",
                area: size.width * size.height,
                isFocused: window.key == focused?.key
            ))
        }
        let plan = BoardPlanner.plan(plannerInput, memory: memory)

        assignments = assignments.filter { $0.value.displayID != target.id }
        stages[target.id] = []

        let geo = geometry(for: target)
        var placed = 0
        var hero: AXWindow?
        var usedRects = Set<String>()
        for entry in plan {
            guard let window = byKey[entry.key], let rect = geo.rect(for: entry.slot) else { continue }
            // With the side boards unsplit, a bottom pane and its top pane share
            // one rectangle; the extra window is left where it is rather than
            // stacked on top of the one already there.
            let rectKey = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            guard usedRects.insert(rectKey).inserted else { continue }
            driver.ensureVisible(window)
            guard driver.setFrame(boardRect(rect, on: target), of: window.element) else { continue }
            assignments[window.key] = Placement(displayID: target.id, slot: entry.slot)
            prefs.remember(entry.slot, bundleID: window.bundleID, displayID: target.id)
            if entry.slot == .center {
                pushStage(window.key, displayID: target.id)
                hero = window
            }
            placed += 1
        }

        if ProcessInfo.processInfo.environment["SIGHTLINE_VERBOSE"] != nil {
            let summary = plan.map { entry in
                "\(byKey[entry.key]?.appName ?? "?")→\(entry.slot.label)"
            }.joined(separator: " ")
            let line = "arrange plan: \(summary)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        if let hero { driver.focus(hero) }
        guard placed > 0 else {
            report("Couldn't arrange any window")
            return 0
        }
        report(placed == 1 ? "Arranged 1 window" : "Arranged \(placed) windows", over: usable)
        return placed
    }

    // MARK: - Moving between boards

    func hop(_ direction: HopDirection) {
        guard let window = driver.focusedWindow(),
              let frame = driver.frame(of: window.element),
              let screen = displays.screen(for: frame) else {
            report("No window is focused")
            return
        }
        let geo = geometry(for: screen)
        guard let current = currentSlot(of: window, on: screen, geo: geo, frame: frame) else {
            report("This window isn't on a board yet — place it first")
            return
        }
        guard let destination = neighbor(of: current, direction: direction) else {
            report("\(current.label) is the edge")
            return
        }
        let target = geo.layout.splitSides ? destination : geo.canonical(destination)
        if geo.canonical(target) == current {
            report("Already at \(current.label)")
            return
        }
        perform(window: window, slot: target, screen: screen)
    }

    private func currentSlot(of window: AXWindow, on screen: ScreenInfo, geo: LayoutGeometry, frame: CGRect) -> Slot? {
        if let placement = assignments[window.key], placement.displayID == screen.id,
           let expected = geo.rect(for: placement.slot),
           WindowDriver.matches(frame, expected, tolerance: 4) {
            return geo.canonical(placement.slot)
        }
        var best: (Slot, CGFloat)?
        for slot in Slot.allCases {
            guard let rect = geo.rect(for: slot) else { continue }
            let intersection = rect.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > (best?.1 ?? 0) { best = (slot, area) }
        }
        guard let best, frame.width * frame.height > 0 else { return nil }
        guard best.1 / (frame.width * frame.height) > 0.55 else { return nil }
        return geo.canonical(best.0)
    }

    private func neighbor(of slot: Slot, direction: HopDirection) -> Slot? {
        switch direction {
        case .left:
            switch slot {
            case .center: return .leftTop
            case .rightTop, .rightBottom: return .center
            default: return nil
            }
        case .right:
            switch slot {
            case .center: return .rightTop
            case .leftTop, .leftBottom: return .center
            default: return nil
            }
        case .up:
            switch slot {
            case .leftBottom: return .leftTop
            case .rightBottom: return .rightTop
            default: return nil
            }
        case .down:
            switch slot {
            case .leftTop: return .leftBottom
            case .rightTop: return .rightBottom
            default: return nil
            }
        }
    }

    // MARK: - The centre stage

    func stageFocusedWindow() {
        guard let window = driver.focusedWindow(),
              let frame = driver.frame(of: window.element),
              let screen = displays.screen(for: frame) else {
            report("No window is focused")
            return
        }
        perform(window: window, slot: .center, screen: screen)
    }

    func cycleStage(backwards: Bool = false) {
        guard let screen = activeScreen(), let centerRect = geometry(for: screen).rect(for: .center) else { return }
        stages[screen.id] = (stages[screen.id] ?? []).filter { driver.resolve($0) != nil }

        var list = stages[screen.id] ?? []
        if list.isEmpty, let window = driver.focusedWindow(), let frame = driver.frame(of: window.element),
           WindowDriver.matches(frame, centerRect, tolerance: 6) {
            list = [window.key]
            stages[screen.id] = list
        }
        guard !list.isEmpty else {
            report("Choose Centre stage → Stage focused window to add a window")
            return
        }
        guard list.count > 1 else {
            report("Only one window on the stage")
            return
        }

        var rotated = list
        if backwards {
            rotated.insert(rotated.removeLast(), at: 0)
        } else {
            rotated.append(rotated.removeFirst())
        }
        guard let nextKey = rotated.first, let window = driver.resolve(nextKey) else { return }

        stages[screen.id] = rotated
        if perform(window: window, slot: .center, screen: screen, updateStage: false) {
            let index = (rotated.firstIndex(of: window.key) ?? 0) + 1
            report("Stage \(index)/\(rotated.count) · \(shortTitle(window))", over: centerRect)
        }
    }

    func clearStage() {
        guard let screen = activeScreen() else { return }
        stages[screen.id] = []
        report("Stage cleared")
    }

    var stagedWindows: [AXWindow] {
        guard let screen = activeScreen() else { return [] }
        return (stages[screen.id] ?? []).compactMap { driver.resolve($0) }
    }

    private func pushStage(_ key: WindowKey, displayID: String) {
        var list = stages[displayID] ?? []
        list.removeAll { $0 == key }
        list.insert(key, at: 0)
        if list.count > 16 { list = Array(list.prefix(16)) }
        stages[displayID] = list
    }

    // MARK: - Layout changes

    func toggleSplit() {
        guard let screen = activeScreen() else { return }
        prefs.toggleSplit(displayID: screen.id)
        report(prefs.layout(for: screen.id).splitSides ? "Side boards split" : "Side boards merged")
    }

    func nudgeCenter(_ delta: Double) {
        guard let screen = activeScreen() else { return }
        prefs.nudgeCenterFraction(by: delta, displayID: screen.id)
        report("Centre \(Int((prefs.layout(for: screen.id).centerFraction * 100).rounded()))%")
    }

    func apply(preset: LayoutPreset, to screen: ScreenInfo) {
        var updated = layout(for: screen)
        updated.centerFraction = preset.centerFraction
        prefs.setLayout(updated, for: screen.id)
    }

    /// Re-applies every tracked window to its slot. Used after any layout change
    /// so the desktop follows the new proportions immediately.
    func reflow() {
        for (key, placement) in assignments {
            guard let screen = displays.screen(id: placement.displayID),
                  let raw = geometry(for: screen).rect(for: placement.slot),
                  let window = driver.resolve(key) else { continue }
            driver.setFrame(boardRect(raw, on: screen), of: window.element)
        }
    }

    // MARK: - Whole-screen verbs

    func fillScreen() {
        guard let window = driver.focusedWindow(),
              let frame = driver.frame(of: window.element),
              let screen = displays.screen(for: frame) else { return }
        driver.ensureVisible(window)
        driver.setFrame(screen.usableFrame, of: window.element)
        assignments[window.key] = nil
        report("Filled \(screen.name)", over: screen.usableFrame)
    }

    func centerAtCurrentSize() {
        guard let window = driver.focusedWindow(),
              let frame = driver.frame(of: window.element),
              let screen = displays.screen(for: frame) else { return }
        let size = CGSize(width: min(frame.width, screen.usableFrame.width),
                          height: min(frame.height, screen.usableFrame.height))
        let target = CGRect(
            x: screen.usableFrame.midX - size.width / 2,
            y: screen.usableFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
        driver.setFrame(target, of: window.element)
        assignments[window.key] = nil
        report("Centred at current size", over: target)
    }

    // MARK: - Arrangements

    private var arrangementURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sightline", isDirectory: true)
            .appendingPathComponent("arrangement.json")
    }

    func saveArrangement() {
        var entries: [ArrangementEntry] = []
        for (key, placement) in assignments {
            guard let window = driver.resolve(key) else { continue }
            entries.append(ArrangementEntry(
                bundleID: window.bundleID,
                appName: window.appName,
                title: key.title,
                slot: placement.slot,
                displayID: placement.displayID
            ))
        }
        guard !entries.isEmpty else {
            report("Nothing to save — place some windows on the boards first")
            return
        }
        let arrangement = Arrangement(savedAt: Date(), entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: arrangementURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(arrangement).write(to: arrangementURL, options: .atomic)
            report("Saved \(entries.count) windows")
        } catch {
            report("Couldn't save: \(error.localizedDescription)")
        }
    }

    func restoreArrangement() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: arrangementURL),
              let arrangement = try? decoder.decode(Arrangement.self, from: data) else {
            report("No saved arrangement yet")
            return
        }
        var restored = 0
        var used: Set<WindowKey> = []
        for entry in arrangement.entries {
            guard let screen = displays.screen(id: entry.displayID) ?? displays.primary,
                  let window = findWindow(for: entry, excluding: used) else { continue }
            if perform(window: window, slot: entry.slot, screen: screen) {
                used.insert(window.key)
                restored += 1
            }
        }
        report(restored > 0 ? "Restored \(restored) windows" : "Couldn't find the saved windows")
    }

    func revealArrangementFile() {
        NSWorkspace.shared.activateFileViewerSelecting([arrangementURL])
    }

    private func findWindow(for entry: ArrangementEntry, excluding used: Set<WindowKey>) -> AXWindow? {
        var candidates: [AXWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let bundle = entry.bundleID, app.bundleIdentifier != bundle { continue }
            candidates += driver.windows(ofApp: app.processIdentifier)
        }
        let available = candidates.filter { !used.contains($0.key) }
        if let exact = available.first(where: { !entry.title.isEmpty && $0.key.title == entry.title }) {
            return exact
        }
        if let partial = available.first(where: {
            !entry.title.isEmpty && ($0.key.title.contains(entry.title) || entry.title.contains($0.key.title))
        }) {
            return partial
        }
        return available.first
    }

    // MARK: - Utilities

    private func activeScreen() -> ScreenInfo? {
        if let window = driver.focusedWindow(), let frame = driver.frame(of: window.element) {
            return displays.screen(for: frame)
        }
        let mouse = NSEvent.mouseLocation
        let axPoint = CGPoint(x: mouse.x, y: displays.systemPrimaryHeight - mouse.y)
        return displays.screen(at: axPoint)
    }

    private func shortTitle(_ window: AXWindow) -> String {
        let name = window.key.title.isEmpty ? window.appName : window.key.title
        return name.count > 34 ? String(name.prefix(33)) + "…" : name
    }

    private func report(_ text: String, over rect: CGRect? = nil) {
        onStatus?(text, rect)
    }

    static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result.integral
    }
}
