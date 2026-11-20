import AppKit
import Foundation
import SightlineCore

// Sightline CLI — reports the live display geometry, the layout that the app
// would apply, and the visual angles that justify it. Useful for verification
// and for scripting.

func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

func screenUUID(_ id: CGDirectDisplayID) -> String {
    guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "unknown" }
    return CFUUIDCreateString(nil, cf) as String
}

func screens(avoidDock: Bool) -> [ScreenInfo] {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSScreen.screens.map { screen in
        let nsFrame = screen.frame
        var usable = nsFrame
        if avoidDock {
            usable = screen.visibleFrame
        } else {
            let topInset = max(0, nsFrame.maxY - screen.visibleFrame.maxY)
            usable = CGRect(x: nsFrame.minX, y: nsFrame.minY,
                            width: nsFrame.width, height: nsFrame.height - topInset)
        }
        let axFrame = ScreenSpace.axRect(fromAppKit: nsFrame, primaryHeight: primaryHeight)
        let axUsable = ScreenSpace.axRect(fromAppKit: usable, primaryHeight: primaryHeight)
        let id = displayID(of: screen) ?? 0
        let size = CGDisplayScreenSize(id)
        return ScreenInfo(
            id: id == 0 ? UUID().uuidString : screenUUID(id),
            name: screen.localizedName,
            frame: axFrame,
            usableFrame: axUsable,
            physicalWidthMM: Double(size.width),
            physicalHeightMM: Double(size.height),
            scale: screen.backingScaleFactor,
            isPrimary: screen == NSScreen.screens.first
        )
    }
}

let args = CommandLine.arguments
let avoidDock = !args.contains("--include-dock")
let allScreens = screens(avoidDock: avoidDock)

guard let screen = allScreens.first(where: { $0.isPrimary }) ?? allScreens.first else {
    print("No screens detected.")
    exit(1)
}

if args.contains("--json") {
    struct SlotOut: Encodable { let slot: String; let x, y, w, h: Double }
    struct PresetOut: Encodable {
        let name: String; let centerFraction: Double; let splitSides: Bool
        let centerHalfAngleDeg: Double; let comfortable: Bool; let slots: [SlotOut]
    }
    struct ScreenOut: Encodable {
        let name: String; let id: String; let frame: [Double]; let usableFrame: [Double]
        let physicalWidthCM: Double; let physicalHeightCM: Double; let scale: Double
        let presets: [PresetOut]
    }
    var presets: [PresetOut] = []
    for p in LayoutPreset.all where p.id != "reader" || args.contains("--all") {
        let layout = p.layout
        let geo = screen.geometry(layout)
        let metrics = AttentionMetrics(frame: screen.usableFrame, layout: layout, geometry: geo,
                                       physicalWidthCM: screen.physicalWidthCM)
        var slots: [SlotOut] = []
        for key in [Slot.center, .leftTop, .leftBottom, .rightTop, .rightBottom] {
            if let r = geo.rects[key], key == geo.canonical(key) {
                slots.append(SlotOut(slot: key.label, x: r.minX, y: r.minY, w: r.width, h: r.height))
            }
        }
        presets.append(PresetOut(name: p.name, centerFraction: p.centerFraction,
                                 splitSides: geo.layout.splitSides,
                                 centerHalfAngleDeg: metrics.centerHalfAngleDeg,
                                 comfortable: metrics.isComfortable, slots: slots))
    }
    let out = ScreenOut(name: screen.name, id: screen.id,
                        frame: [screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height],
                        usableFrame: [screen.usableFrame.minX, screen.usableFrame.minY,
                                      screen.usableFrame.width, screen.usableFrame.height],
                        physicalWidthCM: screen.physicalWidthCM,
                        physicalHeightCM: screen.physicalHeightMM / 10,
                        scale: screen.scale, presets: presets)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(out), let s = String(data: data, encoding: .utf8) { print(s) }
    exit(0)
}

print("Screen: \(screen.name)  [\(screen.id)]  primary=\(screen.isPrimary)")
print(String(format: "  logical frame : %.0f x %.0f pt  (scale %.1fx)", screen.frame.width, screen.frame.height, screen.scale))
print(String(format: "  usable frame  : %.0f x %.0f pt at (%.0f, %.0f)", screen.usableFrame.width, screen.usableFrame.height, screen.usableFrame.minX, screen.usableFrame.minY))
print(String(format: "  physical      : %.1f x %.1f cm", screen.physicalWidthCM, screen.physicalHeightMM / 10))
print("  dock avoided  : \(avoidDock)")

let layout = ScreenLayout.defaultLayout
let geo = screen.geometry(layout)
let metrics = AttentionMetrics(frame: screen.usableFrame, layout: layout, geometry: geo,
                               physicalWidthCM: screen.physicalWidthCM)

print("\nPreset comparison (viewing distance \(Int(layout.viewingDistanceCM)) cm):")
print("  preset      centre%   width   height aspect   ±deg  side pane    comfort")
func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }
for p in LayoutPreset.all {
    let l = p.layout
    let g = screen.geometry(l)
    let c = g.rect(for: .center) ?? .zero
    let s = g.rect(for: .leftTop) ?? .zero
    let m = AttentionMetrics(frame: screen.usableFrame, layout: l, geometry: g, physicalWidthCM: screen.physicalWidthCM)
    let pane = l.splitSides ? String(format: "%.0fx%.0f", s.width, s.height) : "full"
    print(String(format: "  %@ %6.0f%% %7.0f %8.0f %6.2f %6.1f %11@ %@",
                 pad(p.name, 11), p.centerFraction * 100, c.width, c.height, c.width / c.height,
                 m.centerHalfAngleDeg, pad(pane, 11), m.isComfortable ? "yes" : "NO"))
}

print("\nLive slots (\(LayoutPreset.matching(layout.centerFraction)?.name ?? "custom"), split=\(layout.splitSides)):")
for key in [Slot.center, .leftTop, .leftBottom, .rightTop, .rightBottom] {
    guard let r = geo.rects[key] else { continue }
    let dup = key != geo.canonical(key) ? "  (= \(geo.canonical(key).label) when unsplit)" : ""
    print(String(format: "  %-3@ x=%5.0f y=%5.0f  %4.0f x %4.0f%@", pad(key.label, 3), r.minX, r.minY, r.width, r.height, dup))
}
print(String(format: "  centre half-angle %.1f° (limit %.0f°), side band %.1f°–%.1f°, panel half-angle %.1f°",
             metrics.centerHalfAngleDeg, Attention.comfortHalfAngleDeg,
             metrics.sideInnerAngleDeg, metrics.sideOuterAngleDeg, metrics.screenHalfAngleDeg))
