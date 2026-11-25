import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import SightlineCore

final class CentreSwapTests: XCTestCase {
    private let chord: CGEventFlags = [.maskControl, .maskCommand]

    func testSelectCorrectAndCommitOnceOnEitherModifierRelease() {
        for remaining in [CGEventFlags.maskControl, .maskCommand] {
            var updates: [CentreSwapUpdate] = []
            let input = CentreSwapInput { updates.append($0) }
            for key in [kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow, kVK_DownArrow] {
                XCTAssertTrue(input.consumes(.keyDown, key: key, flags: chord, repeated: false))
            }
            XCTAssertEqual(updates, [
                .preview(SwapSelection(left: true)), .preview(SwapSelection(left: false)),
                .preview(SwapSelection(left: false, lower: true)), .preview(SwapSelection(left: false)),
                .preview(SwapSelection(left: false, lower: true))
            ])
            XCTAssertFalse(input.consumes(.flagsChanged, key: 0, flags: remaining, repeated: false))
            XCTAssertFalse(input.consumes(.flagsChanged, key: 0, flags: [], repeated: false))
            XCTAssertTrue(input.consumes(.keyUp, key: kVK_DownArrow, flags: [], repeated: false))
            XCTAssertEqual(updates.filter { $0 == .commit }.count, 1)
        }
    }

    func testStandaloneKeysAndOtherShortcutsPassThrough() {
        let input = CentreSwapInput { _ in XCTFail("Unexpected gesture") }
        for key in [kVK_UpArrow, kVK_DownArrow, kVK_ANSI_1] {
            XCTAssertFalse(input.consumes(.keyDown, key: key, flags: chord, repeated: false))
            XCTAssertFalse(input.consumes(.keyUp, key: key, flags: chord, repeated: false))
        }
        for flags: CGEventFlags in [[], .maskControl, [.maskControl, .maskAlternate], chord.union(.maskShift)] {
            XCTAssertFalse(input.consumes(.keyDown, key: kVK_LeftArrow, flags: flags, repeated: false))
        }
    }

    func testHeldKeysExtraModifiersAndInterruptedGesture() {
        var updates: [CentreSwapUpdate] = []
        let input = CentreSwapInput { updates.append($0) }
        XCTAssertTrue(input.consumes(.keyDown, key: kVK_LeftArrow, flags: chord.union(.maskSecondaryFn), repeated: false))
        XCTAssertTrue(input.consumes(.keyDown, key: kVK_LeftArrow, flags: chord, repeated: true))
        XCTAssertFalse(input.consumes(.flagsChanged, key: 0, flags: chord.union(.maskAlternate), repeated: false))
        XCTAssertTrue(input.consumes(.keyUp, key: kVK_LeftArrow, flags: [], repeated: false))
        XCTAssertTrue(input.consumes(.keyDown, key: kVK_RightArrow, flags: chord, repeated: false))
        input.reset()
        XCTAssertFalse(input.consumes(.flagsChanged, key: 0, flags: [], repeated: false))
        XCTAssertEqual(updates, [.preview(SwapSelection(left: true)), .cancel, .preview(SwapSelection(left: false)), .cancel])
    }

    func testOccupiedPanesInBothLayouts() {
        let left = SwapSelection(left: true)
        let lowerLeft = SwapSelection(left: true, lower: true)
        let right = SwapSelection(left: false)
        let five = Set(Slot.allCases)
        XCTAssertEqual(left.slot(among: five), .leftTop)
        XCTAssertEqual(lowerLeft.slot(among: five), .leftBottom)
        XCTAssertEqual(right.slot(among: [.rightBottom]), .rightBottom)
        XCTAssertEqual(lowerLeft.slot(among: [.leftTop, .center, .rightTop]), .leftTop)
        XCTAssertNil(left.slot(among: [.center, .rightTop]))
    }
}
