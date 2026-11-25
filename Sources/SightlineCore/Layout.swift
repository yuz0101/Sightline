import Foundation
import CoreGraphics

// MARK: - Slots

/// A logical destination for a window. The five slots exist in both geometry
/// modes; when side boards are unsplit, `leftBottom`/`rightBottom` resolve to
/// the same rect as their tops (see `canonical(_:)`).
public enum Slot: String, Codable, CaseIterable, Sendable {
    case center
    case leftTop
    case leftBottom
    case rightTop
    case rightBottom

    public var label: String {
        switch self {
        case .center: return "C"
        case .leftTop: return "LT"
        case .leftBottom: return "LB"
        case .rightTop: return "RT"
        case .rightBottom: return "RB"
        }
    }

    public var title: String {
        switch self {
        case .center: return "Centre"
        case .leftTop: return "Left top"
        case .leftBottom: return "Left bottom"
        case .rightTop: return "Right top"
        case .rightBottom: return "Right bottom"
        }
    }

    /// Left-to-right ordering used by "hop" navigation.
    public var columnIndex: Int {
        switch self {
        case .leftTop, .leftBottom: return 0
        case .center: return 1
        case .rightTop, .rightBottom: return 2
        }
    }

    public var isLeft: Bool { columnIndex == 0 }
    public var isRight: Bool { columnIndex == 2 }
    public var isTop: Bool { self == .leftTop || self == .rightTop }
    public var isBottom: Bool { self == .leftBottom || self == .rightBottom }
}

// MARK: - Layout

/// Pure description of the triptych proportions. No AppKit, no side effects.
public struct ScreenLayout: Codable, Equatable, Sendable {
    /// Fraction of usable width given to the centre board (0.40 ... 0.70).
    public var centerFraction: Double
    /// Each side column split into two equal panes.
    public var splitSides: Bool
    /// Gap between boards, in points. Zero: boards abut exactly, so a window
    /// never shows wallpaper between itself and its neighbour. Kept in the model
    /// so the geometry stays testable with a gutter, but the app always uses 0.
    public var gap: Double
    /// Margin at the outer screen edges, in points.
    public var outerMargin: Double
    /// Assumed eye-to-screen distance, used only for reporting visual angles.
    public var viewingDistanceCM: Double

    public init(
        centerFraction: Double = 0.55,
        splitSides: Bool = true,
        gap: Double = 0,
        outerMargin: Double = 0,
        viewingDistanceCM: Double = 65
    ) {
        self.centerFraction = centerFraction
        self.splitSides = splitSides
        self.gap = gap
        self.outerMargin = outerMargin
        self.viewingDistanceCM = viewingDistanceCM
    }

    public static let defaultLayout = ScreenLayout()
}

public struct LayoutPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let blurb: String
    public let centerFraction: Double
    public var layout: ScreenLayout {
        var l = ScreenLayout.defaultLayout
        l.centerFraction = centerFraction
        return l
    }
    public static let all: [LayoutPreset] = [
        .init(id: "reader", name: "Reader", blurb: "Portrait-ish centre for long-form reading", centerFraction: 0.44),
        .init(id: "aware", name: "Aware", blurb: "Three roughly equal tasks", centerFraction: 0.50),
        .init(id: "balance", name: "Balance", blurb: "Coding, design, general work", centerFraction: 0.55),
        .init(id: "focus", name: "Deep Focus", blurb: "One task, everything else ambient", centerFraction: 0.60),
        .init(id: "wide", name: "Wide", blurb: "Timelines and video", centerFraction: 0.66),
    ]
    public static func named(_ id: String) -> LayoutPreset? { all.first { $0.id == id } }
    public static func matching(_ fraction: Double) -> LayoutPreset? {
        all.first { abs($0.centerFraction - fraction) < 0.005 }
    }
}

// MARK: - Geometry

public struct LayoutGeometry: Sendable {
    public let frame: CGRect
    public let layout: ScreenLayout
    public let rects: [Slot: CGRect]

    public init(frame: CGRect, layout: ScreenLayout) {
        self.frame = frame
        self.layout = layout

        let c = min(max(layout.centerFraction, 0.30), 0.80)
        let outer = max(0, layout.outerMargin)
        let gap = max(0, layout.gap)
        let innerW = max(0, frame.width - outer * 2)
        let innerH = max(0, frame.height - outer * 2)

        let centerW = (innerW * c).rounded()
        let sideW = ((innerW - centerW - gap * 2) / 2).rounded(.down)
        let leftX = frame.minX + outer
        let rightX = leftX + centerW + gap * 2 + sideW
        let centerX = leftX + sideW + gap

        var result: [Slot: CGRect] = [:]
        let fullHeight = CGRect(x: leftX, y: frame.minY + outer, width: centerW, height: innerH)

        if layout.splitSides {
            // Odd heights cannot split evenly; the bottom pane absorbs the
            // leftover point so the column still ends flush with the frame.
            let topH = ((innerH - gap) / 2).rounded(.down)
            let bottomH = innerH - gap - topH
            let topY = frame.minY + outer
            let bottomY = topY + topH + gap
            result[.leftTop] = CGRect(x: leftX, y: topY, width: sideW, height: topH)
            result[.leftBottom] = CGRect(x: leftX, y: bottomY, width: sideW, height: bottomH)
            result[.rightTop] = CGRect(x: rightX, y: topY, width: sideW, height: topH)
            result[.rightBottom] = CGRect(x: rightX, y: bottomY, width: sideW, height: bottomH)
        } else {
            let sideRect = CGRect(x: leftX, y: frame.minY + outer, width: sideW, height: innerH)
            let rightRect = CGRect(x: rightX, y: frame.minY + outer, width: sideW, height: innerH)
            result[.leftTop] = sideRect
            result[.leftBottom] = sideRect
            result[.rightTop] = rightRect
            result[.rightBottom] = rightRect
        }

        result[.center] = CGRect(x: centerX, y: fullHeight.minY, width: centerW, height: innerH)
        self.rects = result
    }

    /// When the sides are not split, bottom slots collapse onto their tops.
    public func canonical(_ slot: Slot) -> Slot {
        guard !layout.splitSides else { return slot }
        switch slot {
        case .leftBottom: return .leftTop
        case .rightBottom: return .rightTop
        default: return slot
        }
    }

    public var boards: [(Slot, CGRect)] {
        Slot.allCases.compactMap { slot in
            guard canonical(slot) == slot, let rect = rects[slot] else { return nil }
            return (slot, rect)
        }
    }

    public func rect(for slot: Slot) -> CGRect? {
        rects[canonical(slot)]
    }
}

// MARK: - Attention math

public enum Attention {
    /// Horizontal half-angle subtended by a half-width, in degrees.
    public static func halfAngleDeg(halfWidthCM: Double, distanceCM: Double) -> Double {
        guard distanceCM > 0 else { return 0 }
        return atan(halfWidthCM / distanceCM) * 180 / .pi
    }

    public static func halfWidthCM(forHalfAngleDeg deg: Double, distanceCM: Double) -> Double {
        tan(deg * .pi / 180) * distanceCM
    }

    /// Comfort cone: the horizontal half-angle a centred board may subtend
    /// before the eyes (or head) must move to read its edges.
    public static let comfortHalfAngleDeg: Double = 22
}

public struct AttentionMetrics: Sendable {
    public let centerWidthCM: Double
    public let centerHalfAngleDeg: Double
    public let centerFullAngleDeg: Double
    public let sideInnerAngleDeg: Double
    public let sideOuterAngleDeg: Double
    public let distanceCM: Double
    public let isComfortable: Bool
    /// Physical half-angle of the whole panel, for context in the UI.
    public let screenHalfAngleDeg: Double

    public init(frame: CGRect, layout: ScreenLayout, geometry: LayoutGeometry,
                physicalWidthCM: Double) {
        let d = max(1, layout.viewingDistanceCM)
        self.distanceCM = d
        guard frame.width > 0, physicalWidthCM > 0 else {
            centerWidthCM = 0; centerHalfAngleDeg = 0; centerFullAngleDeg = 0
            sideInnerAngleDeg = 0; sideOuterAngleDeg = 0
            isComfortable = true; screenHalfAngleDeg = 0
            return
        }
        let cmPerPoint = physicalWidthCM / frame.width
        let midX = frame.midX
        let c = geometry.rect(for: .center) ?? .zero
        let s = geometry.rect(for: .leftTop) ?? .zero
        centerWidthCM = c.width * cmPerPoint
        centerHalfAngleDeg = Attention.halfAngleDeg(halfWidthCM: (c.maxX - midX) * cmPerPoint, distanceCM: d)
        centerFullAngleDeg = centerHalfAngleDeg * 2
        sideInnerAngleDeg = Attention.halfAngleDeg(halfWidthCM: (midX - c.minX) * cmPerPoint, distanceCM: d)
        sideOuterAngleDeg = Attention.halfAngleDeg(halfWidthCM: (midX - s.minX) * cmPerPoint, distanceCM: d)
        screenHalfAngleDeg = Attention.halfAngleDeg(halfWidthCM: frame.width / 2 * cmPerPoint, distanceCM: d)
        isComfortable = centerHalfAngleDeg <= Attention.comfortHalfAngleDeg + 0.05
    }
}

// MARK: - Screen description

public struct ScreenInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Full frame in AX (top-left origin) global coordinates.
    public let frame: CGRect
    /// Layout area: menu bar (and Dock, if avoided) excluded.
    public let usableFrame: CGRect
    public let physicalWidthMM: Double
    public let physicalHeightMM: Double
    public let scale: Double
    public let isPrimary: Bool

    public init(id: String, name: String, frame: CGRect, usableFrame: CGRect,
                physicalWidthMM: Double, physicalHeightMM: Double, scale: Double, isPrimary: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.usableFrame = usableFrame
        self.physicalWidthMM = physicalWidthMM
        self.physicalHeightMM = physicalHeightMM
        self.scale = scale
        self.isPrimary = isPrimary
    }

    public var physicalWidthCM: Double { physicalWidthMM / 10 }
    /// Falls back to the frame's aspect ratio when the panel reports no size.
    public var physicalHeightCM: Double {
        if physicalHeightMM > 0 { return physicalHeightMM / 10 }
        guard frame.width > 0 else { return 0 }
        return physicalWidthCM * Double(frame.height / frame.width)
    }
    public var aspect: Double { frame.height > 0 ? frame.width / frame.height : 0 }

    public func geometry(_ layout: ScreenLayout) -> LayoutGeometry {
        LayoutGeometry(frame: usableFrame, layout: layout)
    }
}

// MARK: - Coordinate conversion

public enum ScreenSpace {
    /// Converts an AppKit rect (bottom-left origin, y up) to AX coordinates
    /// (top-left origin, y down) for a given primary-screen height.
    public static func axRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func appKitRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
