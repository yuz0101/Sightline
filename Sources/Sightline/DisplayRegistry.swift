import AppKit
import SightlineCore

/// Enumerates the live displays and maps them into the AX coordinate space that
/// all window geometry uses.
@MainActor
final class DisplayRegistry {
    private let prefs: Preferences
    private(set) var screens: [ScreenInfo] = []

    init(prefs: Preferences) {
        self.prefs = prefs
        refresh()
    }

    var primary: ScreenInfo? { screens.first(where: { $0.isPrimary }) ?? screens.first }

    var systemPrimaryHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    func refresh() {
        let primaryHeight = systemPrimaryHeight
        let avoidDock = prefs.avoidDock
        screens = NSScreen.screens.map { ns in
            let displayID = Self.displayID(ns)
            let uuid = displayID.map(Self.uuidString) ?? "unknown-\(ns.localizedName)"
            let physical = displayID.map(CGDisplayScreenSize) ?? .zero

            let usableNS: CGRect
            if avoidDock {
                usableNS = ns.visibleFrame
            } else {
                let topInset = max(0, ns.frame.maxY - ns.visibleFrame.maxY)
                usableNS = CGRect(x: ns.frame.minX, y: ns.frame.minY,
                                  width: ns.frame.width,
                                  height: max(0, ns.frame.height - topInset))
            }

            return ScreenInfo(
                id: uuid,
                name: ns.localizedName,
                frame: ScreenSpace.axRect(fromAppKit: ns.frame, primaryHeight: primaryHeight),
                usableFrame: ScreenSpace.axRect(fromAppKit: usableNS, primaryHeight: primaryHeight),
                physicalWidthMM: Double(physical.width),
                physicalHeightMM: Double(physical.height),
                scale: ns.backingScaleFactor,
                isPrimary: ns == NSScreen.screens.first
            )
        }
    }

    /// Signature of the live usable areas, read straight from AppKit rather than
    /// from the cached snapshot, so the Dock moving or resizing can be detected.
    var liveSignature: String {
        let primaryHeight = systemPrimaryHeight
        let avoidDock = prefs.avoidDock
        return NSScreen.screens.map { ns in
            let v: CGRect
            if avoidDock {
                v = ns.visibleFrame
            } else {
                let topInset = max(0, ns.frame.maxY - ns.visibleFrame.maxY)
                v = CGRect(x: ns.frame.minX, y: ns.frame.minY,
                           width: ns.frame.width, height: max(0, ns.frame.height - topInset))
            }
            let ax = ScreenSpace.axRect(fromAppKit: v, primaryHeight: primaryHeight)
            return String(format: "%@:%.0f,%.0f,%.0f,%.0f",
                          ns.localizedName, ax.minX, ax.minY, ax.width, ax.height)
        }.joined(separator: "|")
    }

    /// Signature of what the cached snapshot currently assumes.
    var signature: String {
        screens.map { screen in
            String(format: "%@:%.0f,%.0f,%.0f,%.0f", screen.name,
                   screen.usableFrame.minX, screen.usableFrame.minY,
                   screen.usableFrame.width, screen.usableFrame.height)
        }.joined(separator: "|")
    }

    func screen(id: String) -> ScreenInfo? { screens.first { $0.id == id } }

    /// Screen containing an AX point, else the primary.
    func screen(at axPoint: CGPoint) -> ScreenInfo? {
        screens.first { $0.frame.contains(axPoint) } ?? primary
    }

    /// Screen with the largest intersection with an AX rect.
    func screen(for axRect: CGRect) -> ScreenInfo? {
        var best: (ScreenInfo, CGFloat)?
        for s in screens {
            let inter = s.frame.intersection(axRect)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > (best?.1 ?? 0) { best = (s, area) }
        }
        return best?.0 ?? primary
    }

    /// AX rect to AppKit rect for a screen (used for HUD positioning).
    func appKitRect(_ axRect: CGRect) -> CGRect {
        ScreenSpace.appKitRect(fromAX: axRect, primaryHeight: systemPrimaryHeight)
    }

    func appKitFrame(of screen: ScreenInfo) -> CGRect {
        ScreenSpace.appKitRect(fromAX: screen.frame, primaryHeight: systemPrimaryHeight)
    }

    private static func displayID(_ ns: NSScreen) -> CGDirectDisplayID? {
        (ns.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func uuidString(_ id: CGDirectDisplayID) -> String {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return (CFUUIDCreateString(nil, cf) as String).lowercased()
    }
}
