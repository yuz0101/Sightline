import CoreGraphics
import Foundation

/// A window that can be placed by **Arrange**. The app layer fills this in from
/// Accessibility, so the decision itself stays pure and testable.
public struct ArrangeCandidate: Equatable, Sendable {
    /// Caller-defined identity, opaque to the planner.
    public var key: String
    /// Used to recall where this app sat last time.
    public var bundleID: String
    /// Larger windows win when nothing else distinguishes them.
    public var area: CGFloat
    /// The window the user was last working in goes to the centre board.
    public var isFocused: Bool

    public init(key: String, bundleID: String, area: CGFloat, isFocused: Bool) {
        self.key = key
        self.bundleID = bundleID
        self.area = area
        self.isFocused = isFocused
    }
}

/// The decision behind **Arrange**: which window goes to which board.
public enum BoardPlanner {
    /// Boards are filled centre first, then the tops, then the bottoms, so a
    /// two- or three-window arrange stays balanced rather than left-heavy.
    public static let order: [Slot] = [.center, .leftTop, .rightTop, .leftBottom, .rightBottom]

    /// - Parameters:
    ///   - candidates: every window Arrangement may move, in no particular order.
    ///   - memory: where each app sat the last time it was placed on this display.
    /// - Returns: at most `order.count` placements, in board order.
    ///
    /// The rules, in order:
    /// 1. The focused window takes the centre board — that is the board the user
    ///    is looking at, so it should hold what they were just doing.
    /// 2. A remaining board is first offered to the largest window that
    ///    remembers sitting there — so a repeat arrange puts an app back where you
    ///    left it even if another window is larger.
    /// 3. Any board still empty takes the largest remaining window. Memory is a
    ///    hint, never a reservation: it only applies when that app is available.
    public static func plan(_ candidates: [ArrangeCandidate],
                            memory: [String: Slot] = [:]) -> [(key: String, slot: Slot)] {
        // Largest first everywhere, so "first match" also means "largest match".
        var pool = candidates.sorted { $0.area > $1.area }
        guard !pool.isEmpty else { return [] }

        var placements: [(key: String, slot: Slot)] = []
        let heroIndex = pool.firstIndex(where: \.isFocused) ?? 0
        let hero = pool.remove(at: heroIndex)
        placements.append((hero.key, .center))
        var filled: Set<Slot> = [.center]

        // Pass 1 — honour memory. A remembered board is claimed before size order
        // can hand an app somewhere else, which is what makes a repeat arrange
        // feel stable rather than merely sorted.
        for slot in order.dropFirst() {
            guard let index = pool.firstIndex(where: { memory[$0.bundleID] == slot }) else { continue }
            placements.append((pool.remove(at: index).key, slot))
            filled.insert(slot)
        }

        // Pass 2 — fill what is left with the largest remaining windows.
        for slot in order.dropFirst() where !filled.contains(slot) {
            guard !pool.isEmpty else { break }
            placements.append((pool.removeFirst().key, slot))
        }

        return placements.sorted { order.firstIndex(of: $0.slot)! < order.firstIndex(of: $1.slot)! }
    }
}
