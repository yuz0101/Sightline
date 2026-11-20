import AppKit
import ApplicationServices
import SightlineCore

/// Drag-to-snap (design milestone M4).
///
/// Hold ⌥ while dragging a window: the five boards light up under a translucent
/// overlay and the one under the pointer is where the window lands on release.
///
/// This deliberately does not go through Carbon. A shortcut can be silently owned
/// by another app and there is no API to find out — but the mouse always works.
///
/// It also stays out of the way of macOS's own edge tiling: nothing happens unless
/// ⌥ is held, so a plain drag to a screen edge still does whatever it did before.
@MainActor
final class DragSnap {
    private enum Constants {
        /// Option, not control: ⌃-click is a secondary click, and macOS would
        /// turn a ⌃-drag on a title bar into a context menu.
        static let modifier = NSEvent.ModifierFlags.option
        /// Ignore jitter — a click is not a drag.
        static let minimumTravel: CGFloat = 26
        /// How far outside the window the pointer may sit at release.
        static let releaseSlack: CGFloat = 16
    }

    private let driver: WindowDriver
    private let displays: DisplayRegistry
    private let snaps: SnapController
    private let prefs: Preferences

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let overlay = DragOverlay()

    private var startPoint: CGPoint?
    /// Resolved on mouse-down, while the window is still sitting on its board:
    /// by the first drag event it has already moved and no longer matches.
    /// The slot is nil for a window that is not on any board — a newly created
    /// window, one parked off the grid, or one on another display.
    private var pressed: (window: AXWindow, slot: Slot?, frame: CGRect)?
    private var session: Session?

    /// The self-test drags Sightline's own scratch windows; real use must not.
    var allowsOwnWindows = false
    /// Set by the app in verbose mode; prints why a drag was ignored.
    var log: ((String) -> Void)?

    private struct Session {
        let screen: ScreenInfo
        var slot: Slot
        let boards: [(Slot, CGRect)]
        /// The board the window was dragged out of, if it started on one. The
        /// occupant of the target board moves here, so the two windows trade places.
        let source: Slot?
        /// Option was held when the drag began: snap even back to the same board.
        let forced: Bool
    }

    init(driver: WindowDriver, displays: DisplayRegistry, snaps: SnapController, prefs: Preferences) {
        self.driver = driver
        self.displays = displays
        self.snaps = snaps
        self.prefs = prefs
    }

    // MARK: - Installation

    func install() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // Global monitors never see this app's own windows; the local one does.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func uninstall() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        reset()
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) {
        guard prefs.dragSnapEnabled else { return }
        switch event.type {
        case .leftMouseDown:
            startPoint = pointer()
            pressed = nil
            if let point = startPoint, let screen = displays.screen(at: point),
               let window = windowAtPress(point),
               let frame = driver.frame(of: window.element) {
                let slot = snaps.trackedSlot(for: window, on: screen)
                pressed = (window, slot, frame)
                log?("press: \(window.displayName) is \(slot.map { "on \($0.label)" } ?? "floating")")
            }
            session = nil
            log?("drag: down")
        case .leftMouseDragged:
            drag(to: pointer(), modifiers: event.modifierFlags)
        case .leftMouseUp:
            finish(at: pointer(), modifiers: event.modifierFlags)
        default:
            break
        }
    }

    private func drag(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let startPoint else {
            log?("drag: dragged without start")
            return
        }
        // Once a gesture has started it stays alive even if Option is let go early:
        // people release the key and the mouse in the same motion, and the key-up
        // usually wins the race. Starting one needs Option or a window already on a
        // board; that decision is made below, once, on the first travelled event.
        let travel = hypot(point.x - startPoint.x, point.y - startPoint.y)
        guard travel >= Constants.minimumTravel else {
            log?("drag: travel \(Int(travel))")
            return
        }
        guard let screen = displays.screen(at: point) else { return }

        if session == nil {
            let boards = boards(for: screen)
            let forcing = modifiers.contains(Constants.modifier)
            if forcing {
                log?("drag: started on \(screen.name)")
                let source = pressed?.slot ?? sourceBoard(for: screen, boards: boards)
                session = Session(screen: screen, slot: .center, boards: boards, source: source, forced: true)
            } else if let pressed, windowMoved(pressed) {
                // Any window the user drags lands on the board it is dropped over —
                // including one the app has never seen before, such as a newly
                // created window. Its old board (if any) becomes the swap source.
                log?("drag: started on \(screen.name) from \(pressed.slot?.label ?? "floating")")
                session = Session(screen: screen, slot: pressed.slot ?? .center, boards: boards,
                                  source: pressed.slot, forced: false)
            } else {
                return
            }
        } else if session?.screen.id != screen.id {
            let boards = boards(for: screen)
            let forced = session?.forced ?? false
            session = Session(screen: screen, slot: .center, boards: boards,
                              source: sourceBoard(for: screen, boards: boards), forced: forced)
        }
        guard var current = session, let slot = slot(at: point, screen: screen, boards: current.boards) else { return }
        current.slot = slot
        session = current
        overlay.show(screen: screen, boards: current.boards, highlight: slot)
    }

    private func finish(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        let hadSession = session != nil
        defer { reset() }
        guard let session else {
            if hadSession { log?("drag: no session at release") }
            return
        }
        guard let slot = slot(at: point, screen: session.screen, boards: session.boards) else {
            log?("drag: no board at \(point)")
            return
        }
        overlay.hide()

        // A drag that begins and ends on the same board leaves the window floating:
        // that is how a window is nudged inside its board without the layout pulling
        // it back. Option forces the snap even then.
        if !session.forced, let source = session.source, source == slot {
            log?("drag: free move inside \(slot.label)")
            return
        }

        // Resolve at release time: the window under the pointer is the one the user
        // just dragged, whatever the focus dance was during the drag.
        guard let window = windowUnderPointer(at: point) else { return }
        commit(window: window, slot: slot, screen: session.screen, swapFrom: session.source)
    }

    /// Test hook: drive the pipeline without synthesising mouse events.
    func debugDrag(window: AXWindow, from start: CGPoint, to end: CGPoint) {
        guard let screen = displays.screen(at: end) else { return }
        let boards = boards(for: screen)
        startPoint = start
        guard let slot = slot(at: end, screen: screen, boards: boards) else { return }
        overlay.show(screen: screen, boards: boards, highlight: slot)
        commit(window: window, slot: slot, screen: screen,
               swapFrom: sourceBoard(for: window, screen: screen, boards: boards))
    }

    /// The board a window starts on, judged by how much of it overlaps each board.
    /// Requires a clear majority so a floating window dropped across a seam does
    /// not pretend it came from a board it only grazed.
    private func sourceBoard(for screen: ScreenInfo, boards: [(Slot, CGRect)]) -> Slot? {
        guard let pressed else { return nil }
        return sourceBoard(for: pressed.window, screen: screen, boards: boards)
    }

    private func sourceBoard(for window: AXWindow, screen: ScreenInfo, boards: [(Slot, CGRect)]) -> Slot? {
        guard let frame = driver.frame(of: window.element) else { return nil }
        let area = frame.width * frame.height
        guard area > 0 else { return nil }
        var best: (Slot, CGFloat)?
        for (slot, rect) in boards {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let share = (overlap.width * overlap.height) / area
            if share > (best?.1 ?? 0) { best = (slot, share) }
        }
        guard let best, best.1 >= 0.5 else { return nil }
        return best.0
    }

    /// True once the window itself is moving. Without this, selecting text or
    /// dragging a selection inside a window would be read as a board move.
    private func windowMoved(_ pressed: (window: AXWindow, slot: Slot?, frame: CGRect)) -> Bool {
        guard let frame = driver.frame(of: pressed.window.element) else { return false }
        let dx: CGFloat = abs(frame.minX - pressed.frame.minX)
        let dy: CGFloat = abs(frame.minY - pressed.frame.minY)
        let dw: CGFloat = abs(frame.width - pressed.frame.width)
        let dh: CGFloat = abs(frame.height - pressed.frame.height)
        return dx + dy + dw + dh >= 8
    }

    /// The window the drag is about to start on, resolved while it is still in
    /// place. Focus is tried first (cheap, and right for an active window); if it
    /// does not contain the press point — focus can still sit on the previously
    /// active window when the click is routed — the frontmost window under the
    /// pointer wins. Stays quiet: this runs on every mouse-down.
    private func windowAtPress(_ point: CGPoint) -> AXWindow? {
        let slack = Constants.releaseSlack
        if let focused = driver.focusedWindow(),
           allowsOwnWindows || focused.key.pid != getpid(),
           let frame = driver.frame(of: focused.element),
           frame.insetBy(dx: -slack, dy: -slack).contains(point) {
            return focused
        }
        for window in driver.allWindows() where allowsOwnWindows || window.key.pid != getpid() {
            guard let frame = driver.frame(of: window.element),
                  frame.insetBy(dx: -slack, dy: -slack).contains(point) else { continue }
            return window
        }
        return nil
    }

    private func windowUnderPointer(at point: CGPoint) -> AXWindow? {
        if let focused = driver.focusedWindow(),
           allowsOwnWindows || focused.key.pid != getpid(),
           let frame = driver.frame(of: focused.element),
           frame.insetBy(dx: -Constants.releaseSlack, dy: -Constants.releaseSlack).contains(point) {
            return focused
        }
        // Focus does not always follow a drag (inactive windows, apps that take a
        // moment to activate). Fall back to the frontmost window that contains the
        // release point; the dragged window is on top, so it wins.
        let candidates = driver.allWindows().filter { allowsOwnWindows || $0.key.pid != getpid() }
        for window in candidates {
            guard let frame = driver.frame(of: window.element) else { continue }
            if frame.insetBy(dx: -Constants.releaseSlack, dy: -Constants.releaseSlack).contains(point) {
                log?("drag: using \(window.displayName) under the pointer, not the focused window")
                return window
            }
        }
        log?("drag: no window under \(point)")
        return nil
    }

    private func commit(window: AXWindow, slot: Slot, screen: ScreenInfo, swapFrom: Slot?) {
        if let swapFrom, swapFrom != slot {
            log?("drag: snapping \(window.key.title) to \(slot.label), swapping from \(swapFrom.label)")
        } else {
            log?("drag: snapping \(window.key.title) to \(slot.label)")
        }
        // AppKit drags windows in a nested event-tracking loop: a main-queue block
        // runs *during* that loop and the drag then overrides our frame on its way
        // out. Scheduling in the default mode defers the move until the drag is over.
        RunLoop.main.perform(inModes: [.default]) { [snaps] in
            MainActor.assumeIsolated {
                _ = snaps.perform(window: window, slot: slot, screen: screen, swapFrom: swapFrom)
            }
        }
    }

    private func dismiss() {
        guard session != nil else { return }
        reset()
    }

    private func reset() {
        startPoint = nil
        pressed = nil
        session = nil
        overlay.hide()
    }

    // MARK: - Geometry

    private func pointer() -> CGPoint {
        let ns = NSEvent.mouseLocation
        return CGPoint(x: ns.x, y: displays.systemPrimaryHeight - ns.y)
    }

    private func boards(for screen: ScreenInfo) -> [(Slot, CGRect)] {
        let geo = screen.geometry(prefs.layout(for: screen.id))
        let seen = Set(Slot.allCases.map { geo.canonical($0) })
        return seen.compactMap { slot in
            geo.rect(for: slot).map { (slot, $0) }
        }
    }

    private func slot(at point: CGPoint, screen: ScreenInfo, boards: [(Slot, CGRect)]) -> Slot? {
        if let hit = boards.first(where: { $0.1.contains(point) }) { return hit.0 }
        // In a gutter, or just outside the usable frame: take the nearest board.
        let nearest = boards.min { lhs, rhs in
            distance(point, lhs.1) < distance(point, rhs.1)
        }
        guard let nearest, distance(point, nearest.1) < 200 else { return nil }
        return nearest.0
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

// MARK: - Overlay

/// A click-through panel over one screen showing the five boards while ⌥ is held.
@MainActor
private final class DragOverlay {
    private var panel: NSPanel?
    private var view: BoardView?

    func show(screen: ScreenInfo, boards: [(Slot, CGRect)], highlight: Slot) {
        guard let (panel, view) = ensurePanel() else { return }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let frame = ScreenSpace.appKitRect(fromAX: screen.usableFrame, primaryHeight: primaryHeight)
        let origin = screen.usableFrame.origin

        let local = boards.map { slot, rect in
            (slot, CGRect(
                x: rect.minX - origin.x,
                y: rect.minY - origin.y,
                width: rect.width,
                height: rect.height
            ))
        }
        view.update(boards: local, highlight: highlight, size: frame.size)

        if panel.frame.size != frame.size {
            panel.setFrame(frame, display: false)
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.10
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func ensurePanel() -> (NSPanel, BoardView)? {
        if let panel, let view { return (panel, view) }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let view = BoardView(frame: .zero)
        panel.contentView = view
        self.panel = panel
        self.view = view
        return (panel, view)
    }
}

private final class BoardView: NSView {
    private var boards: [(Slot, CGRect)] = []
    private var highlight: Slot?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func update(boards: [(Slot, CGRect)], highlight: Slot, size: CGSize) {
        self.boards = boards
        self.highlight = highlight
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.10).setFill()
        bounds.fill()

        for (slot, rect) in boards {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
            if slot == highlight {
                NSColor.controlAccentColor.withAlphaComponent(0.26).setFill()
                path.fill()
                NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
                path.lineWidth = 2.5
                path.stroke()
                drawLabel(slot.label, in: rect, emphasised: true)
            } else {
                NSColor.white.withAlphaComponent(0.055).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.20).setStroke()
                path.lineWidth = 1
                path.stroke()
                drawLabel(slot.label, in: rect, emphasised: false)
            }
        }
    }

    private func drawLabel(_ text: String, in rect: CGRect, emphasised: Bool) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: emphasised ? 34 : 22, weight: emphasised ? .semibold : .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(emphasised ? 0.95 : 0.45),
            .paragraphStyle: style,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}
