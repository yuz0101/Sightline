import XCTest
@testable import SightlineCore

final class LayoutTests: XCTestCase {
    let frame = CGRect(x: 0, y: 25, width: 3360, height: 1393)

    func testDefaultLayoutCoversFullWidth() {
        let geo = LayoutGeometry(frame: frame, layout: ScreenLayout.defaultLayout)
        let c = geo.rects[.center]!
        let l = geo.rects[.leftTop]!
        let r = geo.rects[.rightTop]!
        XCTAssertEqual(l.minX, frame.minX, accuracy: 0.001)
        XCTAssertEqual(r.maxX, frame.maxX, accuracy: 0.001)
        XCTAssertEqual(l.maxX, c.minX, accuracy: 0.001)
        XCTAssertEqual(c.maxX, r.minX, accuracy: 0.001)
        XCTAssertEqual(c.width, 1848, accuracy: 0.5)
        XCTAssertEqual(l.width, r.width, accuracy: 0.001)
        XCTAssertEqual(l.height, r.height, accuracy: 0.001)
        XCTAssertEqual(l.minY, frame.minY, accuracy: 0.001)
    }

    func testSplitIsExactHalves() {
        let layout = ScreenLayout(centerFraction: 0.55, splitSides: true, gap: 0)
        let geo = LayoutGeometry(frame: frame, layout: layout)
        let lt = geo.rects[.leftTop]!
        let lb = geo.rects[.leftBottom]!
        XCTAssertEqual(lb.minY, lt.maxY, accuracy: 0.001, "panes must touch: no gutter")
        XCTAssertEqual(lt.height + lb.height, frame.height, accuracy: 0.001, "column ends flush")
        XCTAssertEqual(lb.maxY, frame.maxY, accuracy: 0.001)
        // Equal panes, up to the single point an odd height cannot split.
        XCTAssertLessThanOrEqual(abs(lt.height - lb.height), 1)
    }

    func testBoardsAbutWithNoGap() {
        var layout = ScreenLayout.defaultLayout
        layout.gap = 0
        let geo = LayoutGeometry(frame: frame, layout: layout)
        let c = geo.rects[.center]!
        let lt = geo.rects[.leftTop]!
        let lb = geo.rects[.leftBottom]!
        let rt = geo.rects[.rightTop]!
        let rb = geo.rects[.rightBottom]!

        // Every shared edge is exactly shared, with no strip of desktop between boards.
        XCTAssertEqual(lt.maxX, c.minX, accuracy: 0.001)
        XCTAssertEqual(c.maxX, rt.minX, accuracy: 0.001)
        XCTAssertEqual(lt.maxY, lb.minY, accuracy: 0.001)
        XCTAssertEqual(rt.maxY, rb.minY, accuracy: 0.001)
        XCTAssertEqual(lt.minY, c.minY, accuracy: 0.001)
        XCTAssertEqual(rb.maxY, c.maxY, accuracy: 0.001)
        XCTAssertEqual(c.height, frame.height, accuracy: 0.001)

        // And the union is the whole usable frame, edge to edge.
        XCTAssertEqual(lt.minX, frame.minX, accuracy: 0.001)
        XCTAssertEqual(rt.maxX, frame.maxX, accuracy: 0.001)
        XCTAssertEqual(c.width + lt.width + rt.width, frame.width, accuracy: 0.001)
    }

    func testUnsplitCanonicalizesBottomSlots() {
        var layout = ScreenLayout.defaultLayout
        layout.splitSides = false
        let geo = LayoutGeometry(frame: frame, layout: layout)
        XCTAssertEqual(geo.rect(for: .leftBottom), geo.rect(for: .leftTop))
        XCTAssertEqual(geo.canonical(.leftBottom), .leftTop)
        XCTAssertEqual(geo.canonical(.center), .center)
    }

    func testNoOverlapBetweenBoards() {
        for c in stride(from: 0.40, through: 0.70, by: 0.01) {
            let geo = LayoutGeometry(frame: frame, layout: ScreenLayout(centerFraction: c))
            let rects = [geo.rects[.center]!, geo.rects[.leftTop]!, geo.rects[.leftBottom]!]
            for i in 0..<rects.count {
                for j in (i + 1)..<rects.count {
                    XCTAssertFalse(rects[i].intersects(rects[j]), "overlap at \(c)")
                }
            }
        }
    }

    func testEverySlotIsIntegral() {
        let geo = LayoutGeometry(frame: frame, layout: ScreenLayout.defaultLayout)
        for (_, r) in geo.rects {
            XCTAssertEqual(r.minX, r.minX.rounded(), accuracy: 0.0001)
            XCTAssertEqual(r.minY, r.minY.rounded(), accuracy: 0.0001)
            XCTAssertEqual(r.width, r.width.rounded(), accuracy: 0.0001)
            XCTAssertEqual(r.height, r.height.rounded(), accuracy: 0.0001)
        }
    }

    func testCenterFractionIsRespected() {
        for c in [0.44, 0.50, 0.55, 0.60, 0.66] {
            let geo = LayoutGeometry(frame: frame, layout: ScreenLayout(centerFraction: c))
            let width = geo.rects[.center]!.width
            XCTAssertEqual(Double(width) / Double(frame.width), c, accuracy: 0.001)
        }
    }

    func testPresetsMatchDesign() {
        let expected: [String: (Double, Double)] = [
            "reader": (0.44, 17.6), "aware": (0.50, 19.8),
            "balance": (0.55, 21.6), "focus": (0.60, 23.4), "wide": (0.66, 25.4),
        ]
        for preset in LayoutPreset.all {
            let geo = LayoutGeometry(frame: frame, layout: preset.layout)
            let m = AttentionMetrics(frame: frame, layout: preset.layout, geometry: geo,
                                     physicalWidthCM: 93.6)
            XCTAssertEqual(preset.centerFraction, expected[preset.id]!.0, accuracy: 0.001)
            XCTAssertEqual(m.centerHalfAngleDeg, expected[preset.id]!.1, accuracy: 0.15,
                           "preset \(preset.id)")
        }
    }

    func testAttentionMathRecoversHalfWidth() {
        let deg = 20.0
        let cm = Attention.halfWidthCM(forHalfAngleDeg: deg, distanceCM: 65)
        XCTAssertEqual(Attention.halfAngleDeg(halfWidthCM: cm, distanceCM: 65), deg, accuracy: 1e-9)
    }

    func testComfortWarningFires() {
        var layout = ScreenLayout.defaultLayout
        layout.centerFraction = 0.70
        let geo = LayoutGeometry(frame: frame, layout: layout)
        let m = AttentionMetrics(frame: frame, layout: layout, geometry: geo, physicalWidthCM: 93.6)
        XCTAssertFalse(m.isComfortable)
    }

    func testScreenSpaceRoundTrip() {
        let ns = CGRect(x: 100, y: 50, width: 800, height: 600)
        let ax = ScreenSpace.axRect(fromAppKit: ns, primaryHeight: 1418)
        XCTAssertEqual(ax.minY, 1418 - 650, accuracy: 0.001)
        XCTAssertEqual(ScreenSpace.appKitRect(fromAX: ax, primaryHeight: 1418), ns)
    }
}
