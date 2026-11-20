import CoreGraphics
import XCTest
@testable import SightlineCore

final class ArrangementTests: XCTestCase {
    private func candidate(_ key: String, _ bundle: String, area: CGFloat, focused: Bool = false) -> ArrangeCandidate {
        ArrangeCandidate(key: key, bundleID: bundle, area: area, isFocused: focused)
    }

    func testFocusedWindowTakesTheCentreBoard() {
        let plan = BoardPlanner.plan([
            candidate("big", "com.apple.Safari", area: 900),
            candidate("small", "com.apple.Notes", area: 100, focused: true),
        ])
        XCTAssertEqual(plan.map(\.key), ["small", "big"])
        XCTAssertEqual(plan.map(\.slot), [.center, .leftTop])
    }

    func testWithoutFocusTheLargestWindowTakesTheCentre() {
        let plan = BoardPlanner.plan([
            candidate("small", "a", area: 100),
            candidate("big", "b", area: 900),
        ])
        XCTAssertEqual(plan.first?.key, "big")
        XCTAssertEqual(plan.first?.slot, .center)
    }

    func testMemoryPutsAnAppBackWhereItSat() {
        // No focus, so memory is the only thing that can override size.
        let plan = BoardPlanner.plan([
            candidate("big", "com.apple.Safari", area: 900),
            candidate("small", "com.apple.Notes", area: 100),
        ], memory: ["com.apple.Notes": .rightBottom])

        XCTAssertEqual(plan.first { $0.key == "small" }?.slot, .rightBottom)
        XCTAssertEqual(plan.first { $0.key == "big" }?.slot, .center)
    }

    func testFocusedWindowOutranksItsOwnMemory() {
        let plan = BoardPlanner.plan([
            candidate("focused", "com.apple.Notes", area: 100, focused: true),
            candidate("other", "com.apple.Safari", area: 900),
        ], memory: ["com.apple.Notes": .leftBottom])

        XCTAssertEqual(plan.first { $0.key == "focused" }?.slot, .center)
        XCTAssertEqual(plan.first { $0.key == "other" }?.slot, .leftTop)
    }

    func testMemoryIsAHintNotAReservation() {
        // Notes remembers the centre, but the focused window owns the centre; the
        // remembered slot is simply unavailable, and Notes falls back to size order.
        let plan = BoardPlanner.plan([
            candidate("focused", "com.apple.Safari", area: 900, focused: true),
            candidate("notes", "com.apple.Notes", area: 100),
        ], memory: ["com.apple.Notes": .center])

        XCTAssertEqual(plan.first { $0.key == "notes" }?.slot, .leftTop)
    }

    func testTwoWindowsOfOneAppDoNotBothTakeTheRememberedBoard() {
        let plan = BoardPlanner.plan([
            candidate("one", "com.apple.Safari", area: 800),
            candidate("two", "com.apple.Safari", area: 400),
            candidate("mail", "com.apple.mail", area: 600, focused: true),
        ], memory: ["com.apple.Safari": .leftTop])

        XCTAssertEqual(plan.first { $0.key == "mail" }?.slot, .center)
        XCTAssertEqual(plan.first { $0.key == "one" }?.slot, .leftTop)
        XCTAssertEqual(plan.first { $0.key == "two" }?.slot, .rightTop)
    }

    func testOnlyFiveBoardsAreFilled() {
        let many = (0..<9).map { candidate("w\($0)", "app\($0)", area: CGFloat(900 - $0)) }
        let plan = BoardPlanner.plan(many)
        XCTAssertEqual(plan.count, 5)
        XCTAssertEqual(plan.map(\.slot), BoardPlanner.order)
    }

    func testEmptyInputProducesNoPlacements() {
        XCTAssertTrue(BoardPlanner.plan([]).isEmpty)
    }
}
