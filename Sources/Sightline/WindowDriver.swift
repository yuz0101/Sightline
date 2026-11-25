import AppKit
import ApplicationServices
import SightlineCore

/// Identity of a window that survives AX round-trips. Chromium-based apps do not
/// answer `_AXUIElementGetWindow` in some versions, so the title is used as a
/// fallback discriminator.
struct WindowKey: Hashable {
    let pid: pid_t
    let number: CGWindowID?
    let title: String

    static func == (lhs: WindowKey, rhs: WindowKey) -> Bool {
        guard lhs.pid == rhs.pid else { return false }
        if let a = lhs.number, let b = rhs.number { return a == b }
        return lhs.title == rhs.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        if let number { hasher.combine(number) } else { hasher.combine(title) }
    }
}

struct VisibleWindow: Equatable {
    let pid: pid_t
    let number: CGWindowID
}

struct AXWindow {
    let element: AXUIElement
    let key: WindowKey
    let bundleID: String?
    let appName: String

    var displayName: String {
        key.title.isEmpty ? appName : "\(appName) — \(key.title)"
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Sightline"

    static func requestPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Thin, defensive wrapper around the Accessibility window API.
@MainActor
final class WindowDriver {
    typealias GetWindowIDFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private let getWindowIDFn: GetWindowIDFn?

    private let onlyOwnWindows: Bool

    init(onlyOwnWindows: Bool = false) {
        self.onlyOwnWindows = onlyOwnWindows
        // Private but stable since 10.10; used by every window manager.
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") {
            getWindowIDFn = unsafeBitCast(symbol, to: GetWindowIDFn.self)
        } else {
            getWindowIDFn = nil
        }
    }

    // MARK: - Element plumbing

    private func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.5)
        return element
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private func flag(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindowIDFn else { return nil }
        var id: CGWindowID = 0
        guard fn(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    // MARK: - Geometry

    func frame(of element: AXUIElement) -> CGRect? {
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var result: CFArray?
        let values: [CFTypeRef]
        if AXUIElementCopyMultipleAttributeValues(element, attributes, [], &result) == .success,
           let pair = result as? [CFTypeRef], pair.count == 2 {
            values = pair
        } else {
            guard let position = copy(element, kAXPositionAttribute),
                  let size = copy(element, kAXSizeAttribute) else { return nil }
            values = [position, size]
        }
        let positionValue = values[0], sizeValue = values[1]
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 1, size.height > 1
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    /// macOS refuses to size a window larger than the screen it currently lives
    /// on, so we go size → position → size and verify with a read-back. A single
    /// retry absorbs the case where the app applied the move asynchronously.
    @discardableResult
    func setFrame(_ target: CGRect, of element: AXUIElement) -> Bool {
        let canResize = isSettable(element, kAXSizeAttribute)
        for attempt in 0..<2 {
            if canResize { setSize(element, target.size) }
            setPosition(element, target.origin)
            if let actual = frame(of: element), Self.matches(actual, target) { return true }
            // Moving to a larger display can lift the old display's size limit.
            if canResize {
                setSize(element, target.size)
                if let actual = frame(of: element), Self.matches(actual, target) { return true }
            }
            if attempt == 0 { usleep(40_000) }
        }
        if let actual = frame(of: element) {
            NSLog("Sightline: setFrame mismatch wanted \(target) got \(actual)")
        }
        return false
    }

    private func setPosition(_ element: AXUIElement, _ origin: CGPoint) {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ element: AXUIElement, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    // MARK: - Discovery

    private func makeHandle(
        _ element: AXUIElement,
        pid: pid_t,
        bundleID: String?,
        appName: String
    ) -> AXWindow? {
        guard string(element, kAXRoleAttribute) == kAXWindowRole else { return nil }
        if let subrole = string(element, kAXSubroleAttribute), subrole != kAXStandardWindowSubrole {
            return nil
        }
        guard frame(of: element) != nil else { return nil }
        let title = string(element, kAXTitleAttribute) ?? ""
        let key = WindowKey(pid: pid, number: windowID(element), title: title)
        return AXWindow(element: element, key: key, bundleID: bundleID, appName: appName)
    }

    private func windowElements(ofApp pid: pid_t) -> [AXUIElement] {
        copy(appElement(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    func windows(ofApp pid: pid_t) -> [AXWindow] {
        let running = NSRunningApplication(processIdentifier: pid)
        let bundleID = running?.bundleIdentifier
        let name = running?.localizedName ?? "Unknown"
        return windowElements(ofApp: pid).compactMap { makeHandle($0, pid: pid, bundleID: bundleID, appName: name) }
    }

    /// All standard windows of all regular apps, in the front-to-back order that
    /// `NSWorkspace` reports applications.
    func allWindows() -> [AXWindow] {
        if onlyOwnWindows { return windows(ofApp: getpid()) }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .flatMap { windows(ofApp: $0.processIdentifier) }
    }

    /// WindowServer provides the current Space's front-to-back order and bounds
    /// in one call. Use AX only for a window that could actually be involved.
    func visibleWindows() -> [(window: VisibleWindow, frame: CGRect)] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !onlyOwnWindows || pid == getpid(),
                  let number = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return (VisibleWindow(pid: pid, number: number), frame)
        }
    }

    func visibleOccupants(of geometry: LayoutGeometry) -> [Slot: VisibleWindow] {
        let boards = geometry.boards
        var occupants: [Slot: VisibleWindow] = [:]
        for (window, frame) in visibleWindows() {
            if let (slot, _) = boards.first(where: { Self.matches(frame, $0.1, tolerance: 8) }),
               occupants[slot] == nil { occupants[slot] = window }
        }
        return occupants
    }

    func resolve(_ visible: VisibleWindow, in rect: CGRect, excluding: AXWindow? = nil) -> AXWindow? {
        let app = NSRunningApplication(processIdentifier: visible.pid)
        for element in windowElements(ofApp: visible.pid) {
            if let excluding, CFEqual(element, excluding.element) { continue }
            if let number = windowID(element), number != visible.number { continue }
            guard let frame = frame(of: element), Self.matches(frame, rect, tolerance: 8),
                  let window = makeHandle(element, pid: visible.pid, bundleID: app?.bundleIdentifier,
                                          appName: app?.localizedName ?? "Unknown"),
                  !isMinimized(window) else { continue }
            return window
        }
        return nil
    }

    func focusedWindow() -> AXWindow? {
        if let front = NSWorkspace.shared.frontmostApplication {
            let element = appElement(front.processIdentifier)
            if let raw = copy(element, kAXFocusedWindowAttribute),
               CFGetTypeID(raw) == AXUIElementGetTypeID(),
               let window = makeHandle(
                   raw as! AXUIElement,
                   pid: front.processIdentifier,
                   bundleID: front.bundleIdentifier,
                   appName: front.localizedName ?? "Unknown"
               ) {
                return window
            }
        }

        // Fallback for panels and apps that do not report a focused window.
        let systemWide = AXUIElementCreateSystemWide()
        guard let rawApp = copy(systemWide, kAXFocusedApplicationAttribute),
              CFGetTypeID(rawApp) == AXUIElementGetTypeID()
        else { return nil }
        let app = rawApp as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        guard pid > 0,
              let rawWindow = copy(app, kAXFocusedWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
        else { return nil }
        let running = NSRunningApplication(processIdentifier: pid)
        return makeHandle(
            rawWindow as! AXUIElement,
            pid: pid,
            bundleID: running?.bundleIdentifier,
            appName: running?.localizedName ?? "Unknown"
        )
    }

    func resolve(_ key: WindowKey) -> AXWindow? {
        let windows = windows(ofApp: key.pid)
        if let number = key.number {
            return windows.first { $0.key.number == number }
        }
        return windows.first { $0.key.title == key.title }
    }

    // MARK: - State changes

    func isMinimized(_ window: AXWindow) -> Bool {
        flag(window.element, kAXMinimizedAttribute) == true
    }

    func ensureVisible(_ window: AXWindow) {
        if flag(window.element, kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            usleep(140_000)
        }
        // Undocumented string attribute; the setter is the only way to leave a
        // native full-screen space on behalf of another app.
        if flag(window.element, "AXFullScreen") == true {
            AXUIElementSetAttributeValue(window.element, "AXFullScreen" as CFString, kCFBooleanFalse)
            usleep(400_000)
        }
    }

    func focus(_ window: AXWindow) {
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: window.key.pid)?.activate()
    }

    func minimize(_ window: AXWindow) {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }
}
