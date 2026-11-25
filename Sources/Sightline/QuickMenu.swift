import AppKit
import CoreGraphics

/// Right-click on the wallpaper pops up a compact Sightline menu, with
/// Arrange at the top; Option + right-click does the same anywhere, including
/// over other apps' windows. Finder owns the desktop's own context menu and
/// gives other apps no way to add to it (a Finder extension only sees files and
/// folders), so the wallpaper menu is ours outright and carries the two Finder
/// commands people actually use there. Right-clicking a Finder window, a file
/// icon or any app window is left alone.
///
/// The tap is active, because a plain NSEvent monitor cannot stop Finder's own
/// menu from opening at the same time. Its run loop lives on a private thread:
/// popping up a menu blocks the main run loop, and a tap installed there gets
/// starved and disabled by the system (measured: the second ⌥-right-click after
/// a menu came back dead).
@MainActor
final class QuickMenu {
    private let prefs: Preferences
    private let perform: (MenuAction) -> Void

    private var state: TapState?
    private var thread: Thread?
    private var isShowing = false
    /// Menu on a plain right-click of the wallpaper; mirrored into `TapState`
    /// because the tap thread reads it without touching the main actor.
    var desktopTakeover = true {
        didSet { state?.setDesktopTakeover(desktopTakeover) }
    }
    private var retry: DispatchWorkItem?
    private var health: Timer?
    private var host: NSWindow?

    var log: ((String) -> Void)?

    init(prefs: Preferences, perform: @escaping (MenuAction) -> Void) {
        self.prefs = prefs
        self.perform = perform
    }

    var isInstalled: Bool { state != nil }

    // MARK: - Installation

    func install() {
        guard state == nil else { return }
        // A LaunchServices launch can briefly report "not trusted" while TCC
        // resolves the bundle. A tap created in that window is inert — it exists
        // but never receives events — so wait for trust and retry instead.
        guard AXIsProcessTrusted() else {
            log?("quick menu: waiting for Accessibility")
            scheduleRetry()
            return
        }
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
        let state = TapState { [weak self] point, onDesktop in
            DispatchQueue.main.async { self?.present(at: point, onDesktop: onDesktop) }
        }
        state.setDesktopTakeover(desktopTakeover)
        let refcon = Unmanaged.passUnretained(state).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: quickMenuTapCallback,
            userInfo: refcon
        ) else {
            log?("quick menu: could not create the event tap, will retry")
            scheduleRetry()
            return
        }
        state.tapPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.state = state

        let thread = Thread { [weak self] in
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            if let port = state.tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            CFRunLoopRun()
            _ = self
        }
        thread.name = "Sightline.quickMenu"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        // A tap can be created already disabled (it shows up enabled only when
        // the first event arrives, which that same event then loses). Checking
        // it on a timer means the very first ⌥-right-click works.
        health?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureTapEnabled() }
        }
        RunLoop.main.add(timer, forMode: .common)
        health = timer
        log?("quick menu: installed")
    }

    private func ensureTapEnabled() {
        guard let state, let tap = state.tapPort else { return }
        guard !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        log?("quick menu: re-enabled the tap")
    }

    private func scheduleRetry() {
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.retry = nil
            self?.install()
        }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func uninstall() {
        retry?.cancel()
        retry = nil
        health?.invalidate()
        health = nil
        if let state, let tap = state.tapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        state = nil
        thread = nil
    }

    // MARK: - Presentation

    private func present(at cgPoint: CGPoint, onDesktop: Bool) {
        guard !isShowing else { return }
        guard let primaryHeight = Self.primaryHeight else { return }
        let appKitPoint = NSPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y)
        let menu = buildMenu(onDesktop: onDesktop)
        isShowing = true
        state?.setShowing(true)
        log?("quick menu: at \(Int(cgPoint.x)),\(Int(cgPoint.y))\(onDesktop ? " (desktop)" : "")")
        log?("quick menu: \(menu.items.count) items \(menu.items.map(\.title).joined(separator: " | "))")
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        // A menu presented in a view is far more reliable than one popped up at
        // a nil view from a background accessory app: the latter returns at once
        // and the menu never appears.
        let panel = NSWindow(contentRect: NSRect(x: appKitPoint.x, y: appKitPoint.y - 1, width: 1, height: 1),
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.makeKeyAndOrderFront(nil)
        host = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let view = panel.contentView else { return }
            menu.popUp(positioning: nil, at: .zero, in: view)
            panel.orderOut(nil)
            self.host = nil
            self.isShowing = false
            self.state?.setShowing(false)
            self.state?.reset()
            self.log?("quick menu: closed")
        }
    }

    /// AppKit's global origin is the bottom-left of the display that holds (0,0);
    /// CoreGraphics (and the tap) count down from its top.
    private static var primaryHeight: CGFloat? {
        let screens = NSScreen.screens
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        return primary?.frame.maxY
    }

    // MARK: - Menu

    private func buildMenu(onDesktop: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(actionItem(.arrangeAll))
        menu.addItem(.separator())

        let place = NSMenu()
        for action in [MenuAction.placeCenter, .placeLeftTop, .placeLeftBottom,
                       .placeRightTop, .placeRightBottom] {
            place.addItem(actionItem(action))
        }
        let placeItem = NSMenuItem(title: "Place focused window", action: nil, keyEquivalent: "")
        placeItem.submenu = place
        menu.addItem(placeItem)

        menu.addItem(actionItem(.cycleForward))
        menu.addItem(actionItem(.stageFocused))
        menu.addItem(.separator())
        if onDesktop {
            // The two Finder commands that belong on the wallpaper; the rest
            // (Use Stacks, Edit Widgets, Get Info) stay with Finder's own menu,
            // which is why this takeover is a setting.
            let newFolder = NSMenuItem(title: "New Folder",
                                       action: #selector(newDesktopFolder),
                                       keyEquivalent: "")
            newFolder.target = self
            menu.addItem(newFolder)
            let wallpaper = NSMenuItem(title: "Change Wallpaper\u{2026}",
                                       action: #selector(changeWallpaper),
                                       keyEquivalent: "")
            wallpaper.target = self
            menu.addItem(wallpaper)
            menu.addItem(.separator())
        }
        menu.addItem(actionItem(.openSettings))

        let quit = NSMenuItem(title: "Quit Sightline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func actionItem(_ action: MenuAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = NSNumber(value: action.rawValue)
        return item
    }

    @objc private func newDesktopFolder() {
        let manager = FileManager.default
        guard let desktop = manager.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        var url = desktop.appendingPathComponent("untitled folder")
        var index = 2
        while manager.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("untitled folder \(index)")
            index += 1
        }
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: false)
            log?("quick menu: new folder \(url.lastPathComponent)")
        } catch {
            log?("quick menu: new folder failed: \(error.localizedDescription)")
        }
    }

    @objc private func changeWallpaper() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
        log?("quick menu: open wallpaper settings")
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber,
              let action = MenuAction(rawValue: number.uint32Value) else { return }
        log?("quick menu: \(action.title)")
        perform(action)
    }
}

// MARK: - Tap state

/// Shared with the tap thread, so it is deliberately outside the main actor.
private final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var showing = false
    private var swallowNextUp = false
    private var desktopTakeover = true
    var tapPort: CFMachPort?
    private let onRightClick: (CGPoint, Bool) -> Void

    init(onRightClick: @escaping (CGPoint, Bool) -> Void) {
        self.onRightClick = onRightClick
    }

    func setDesktopTakeover(_ value: Bool) {
        lock.lock()
        desktopTakeover = value
        lock.unlock()
    }

    var allowsDesktopRightClick: Bool {
        lock.lock()
        defer { lock.unlock() }
        return desktopTakeover
    }

    func setShowing(_ value: Bool) {
        lock.lock()
        showing = value
        lock.unlock()
    }

    /// Returns true when the click should be swallowed and a menu shown.
    func beginClick(at point: CGPoint, onDesktop: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !showing else { return false }
        // A mouse-up can go missing (e.g. the click that closed a menu elsewhere);
        // a fresh press is proof that the previous pair is over.
        swallowNextUp = true
        onRightClick(point, onDesktop)
        return true
    }

    /// True while the menu is open; such a click belongs to the menu.
    var isShowing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return showing
    }

    /// Clears any half-finished click pair, e.g. after the menu closes.
    func reset() {
        lock.lock()
        swallowNextUp = false
        lock.unlock()
    }

    /// Consumes the mouse-up that pairs with a swallowed mouse-down.
    func consumeUp() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard swallowNextUp else { return false }
        swallowNextUp = false
        return true
    }
}

/// True when the point sits on bare desktop wallpaper: no app window covers it
/// and the accessibility element there is the desktop container rather than a
/// file icon or a Dock item (those report `AXImage`, `AXButton`, `AXStaticText`,
/// `AXCell` and so on, and keep their own menus).
private func wallpaperUnderPointer(_ point: CGPoint) -> Bool {
    guard !windowUnderPointer(point) else { return false }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.25)
    var element: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
    guard error == .success, let element else { return true }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let name = role as? String
    return name == nil || name == "AXGroup" || name == "AXWindow"
}

/// True when an ordinary (layer 0) window of another process covers the point.
/// Desktop elements are excluded from the list, so wallpaper is simply "nothing
/// covers this point".
private func windowUnderPointer(_ point: CGPoint) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return false }
    let ownPID = Int(getpid())
    for info in list {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
              let bounds = info[kCGWindowBounds as String] as? [String: Any] else { continue }
        let rect = CGRect(x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                          y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                          width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                          height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
        if rect.contains(point) { return true }
    }
    return false
}

private func quickMenuTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<TapState>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = state.tapPort {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .rightMouseDown || type == .rightMouseUp else {
        return Unmanaged.passUnretained(event)
    }
    // The paired mouse-up is consumed even while the menu is open: leaving it
    // unclaimed strands `swallowNextUp` and the *next* Option-right-click is
    // passed through instead of opening a menu (measured: the second click
    // after a menu went to Finder).
    if type == .rightMouseUp {
        return state.consumeUp() ? nil : Unmanaged.passUnretained(event)
    }
    if state.isShowing { return Unmanaged.passUnretained(event) }
    let option = event.flags.contains(.maskAlternate)
    let point = event.location
    if !option {
        // A plain right-click is ours only on bare wallpaper, and only when the
        // setting is on; Finder windows, file icons and app windows keep theirs.
        guard state.allowsDesktopRightClick, wallpaperUnderPointer(point) else {
            return Unmanaged.passUnretained(event)
        }
    }
    return state.beginClick(at: point, onDesktop: !option) ? nil : Unmanaged.passUnretained(event)
}
