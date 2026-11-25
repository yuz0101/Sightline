import AppKit
import ApplicationServices
import SightlineCore

/// A window dragged across a board boundary snaps on release. Option also
/// allows snapping back into the board where the drag began.
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
    private let overlay = BoardOverlay()

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
            MainActor.assumeIsolated { self?.handle(event, local: false) }
        }
        // Global monitors never see this app's own windows; the local one does.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, local: true) }
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

    private func handle(_ event: NSEvent, local: Bool) {
        guard prefs.dragSnapEnabled else { return }
        switch event.type {
        case .leftMouseDown:
            startPoint = pointer(for: event)
            pressed = nil
            if let point = startPoint, let screen = displays.screen(at: point),
               let window = windowUnderPointer(at: point),
               let frame = driver.frame(of: window.element) {
                let slot = boards(for: screen).first { WindowDriver.matches(frame, $0.1, tolerance: 8) }?.0
                pressed = (window, slot, frame)
                log?("press: \(window.displayName) is \(slot.map { "on \($0.label)" } ?? "floating")")
            }
            session = nil
            log?("drag: down")
        case .leftMouseDragged:
            drag(to: pointer(for: event), modifiers: event.modifierFlags)
        case .leftMouseUp:
            finish(at: pointer(for: event), afterLocalTracking: local)
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

        let previous = session
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
        if previous?.screen.id == screen.id, previous?.slot == slot { return }
        current.slot = slot
        session = current
        overlay.show(screen: screen, boards: current.boards, highlight: slot)
    }

    private func finish(at point: CGPoint, afterLocalTracking: Bool) {
        defer { reset() }
        guard let session else { return }
        guard let slot = slot(at: point, screen: session.screen, boards: session.boards) else {
            log?("drag: no board at \(point)")
            return
        }

        // A drag that begins and ends on the same board leaves the window floating:
        // that is how a window is nudged inside its board without the layout pulling
        // it back. Option forces the snap even then.
        if !session.forced, let source = session.source, source == slot {
            log?("drag: free move inside \(slot.label)")
            return
        }

        // Reuse the exact window captured on press. Focus can change during
        // a native drag, and querying another app here delays the resize.
        let window: AXWindow
        if let pressed, let frame = driver.frame(of: pressed.window.element),
           frame.insetBy(dx: -Constants.releaseSlack, dy: -Constants.releaseSlack).contains(point) {
            window = pressed.window
        } else if let hit = windowUnderPointer(at: point) {
            window = hit
        } else {
            return
        }
        commit(window: window, slot: slot, screen: session.screen,
               swapFrom: session.source, afterLocalTracking: afterLocalTracking)
    }

    /// Test hook: drive the pipeline without synthesising mouse events.
    func debugDrag(window: AXWindow, from start: CGPoint, to end: CGPoint) {
        guard let screen = displays.screen(at: end) else { return }
        let boards = boards(for: screen)
        startPoint = start
        guard let slot = slot(at: end, screen: screen, boards: boards) else { return }
        overlay.show(screen: screen, boards: boards, highlight: slot)
        commit(window: window, slot: slot, screen: screen,
               swapFrom: sourceBoard(for: window, screen: screen, boards: boards), afterLocalTracking: true)
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

    private func windowUnderPointer(at point: CGPoint) -> AXWindow? {
        let windows = driver.visibleWindows()
        let hit = windows.first { $0.frame.contains(point) } ?? windows.first {
            $0.frame.insetBy(dx: -Constants.releaseSlack, dy: -Constants.releaseSlack).contains(point)
        }
        guard let hit, allowsOwnWindows || hit.window.pid != getpid() else { return nil }
        return driver.resolve(hit.window, in: hit.frame)
    }

    private func commit(window: AXWindow, slot: Slot, screen: ScreenInfo, swapFrom: Slot?, afterLocalTracking: Bool) {
        if let swapFrom, swapFrom != slot {
            log?("drag: snapping \(window.key.title) to \(slot.label), swapping from \(swapFrom.label)")
        } else {
            log?("drag: snapping \(window.key.title) to \(slot.label)")
        }
        // An external app owns its own event-tracking loop. Its global mouse-up
        // can snap immediately. Only our local monitor must wait for AppKit to
        // finish tracking a Sightline window before writing that window's frame.
        guard afterLocalTracking else {
            snaps.perform(window: window, slot: slot, screen: screen, swapFrom: swapFrom)
            return
        }
        RunLoop.main.perform(inModes: [.default]) { [snaps] in
            MainActor.assumeIsolated {
                _ = snaps.perform(window: window, slot: slot, screen: screen, swapFrom: swapFrom)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func reset() {
        startPoint = nil
        pressed = nil
        session = nil
        overlay.hide()
    }

    // MARK: - Geometry

    private func pointer(for event: NSEvent) -> CGPoint {
        if let point = event.cgEvent?.location { return point }
        let ns = NSEvent.mouseLocation
        return CGPoint(x: ns.x, y: displays.systemPrimaryHeight - ns.y)
    }

    private func boards(for screen: ScreenInfo) -> [(Slot, CGRect)] {
        screen.geometry(prefs.layout(for: screen.id)).boards
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

/// Shared, non-activating preview for a pending drag or keyboard swap.
@MainActor
final class BoardOverlay {
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

        if panel.frame != frame {
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
        if let panel, panel.isVisible { panel.orderOut(nil) }
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
