import Carbon.HIToolbox
import CoreGraphics

package struct SwapSelection: Equatable {
    let left: Bool
    var lower = false

    package func slot(among occupied: Set<Slot>) -> Slot? {
        let upper: Slot = left ? .leftTop : .rightTop
        let bottom: Slot = left ? .leftBottom : .rightBottom
        let order = lower ? [bottom, upper] : [upper, bottom]
        return order.first(where: occupied.contains)
    }
}

package enum CentreSwapUpdate: Equatable {
    case preview(SwapSelection)
    case commit
    case cancel
}

/// Only a horizontal arrow can begin a gesture. Suppress its matching key-up
/// even when the modifier release arrives first.
package final class CentreSwapInput {
    private var selection: SwapSelection?
    private var consumed = Set<Int>()
    private let send: (CentreSwapUpdate) -> Void

    package init(send: @escaping (CentreSwapUpdate) -> Void) {
        self.send = send
    }

    package func reset() {
        if selection != nil { send(.cancel) }
        selection = nil
        consumed.removeAll()
    }

    package func consumes(_ type: CGEventType, key: Int, flags: CGEventFlags, repeated: Bool) -> Bool {
        let modifiers = flags.intersection([.maskControl, .maskCommand, .maskShift, .maskAlternate])
        let chord: CGEventFlags = [.maskControl, .maskCommand]
        if type == .flagsChanged {
            if selection != nil, modifiers != chord {
                selection = nil
                send(modifiers.isSubset(of: chord) ? .commit : .cancel)
            }
            return false
        }
        if type == .keyUp { return consumed.remove(key) != nil }
        guard type == .keyDown else { return false }
        if repeated { return consumed.contains(key) }
        // A missed key-up must never swallow a subsequent ordinary arrow.
        consumed.remove(key)
        guard modifiers == chord else { return false }

        switch key {
        case kVK_LeftArrow, kVK_RightArrow:
            selection = SwapSelection(left: key == kVK_LeftArrow)
        case kVK_UpArrow, kVK_DownArrow:
            guard selection != nil else { return false }
            selection?.lower = key == kVK_DownArrow
        default:
            if selection != nil {
                selection = nil
                send(.cancel)
            }
            return false
        }
        if let selection { send(.preview(selection)) }
        consumed.insert(key)
        return true
    }
}
