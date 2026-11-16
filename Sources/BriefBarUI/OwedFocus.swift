/// The card a key, or a drop, just moved while it had the keyboard's focus, which takes the focus back as it's drawn anew
/// in its new column: owed it until it does, or until that move's wait for it ends. Not when an earlier move's wait ends,
/// as when you press the next key just as the last one's wait ends, or the Mac is busy until then: the card is owed it
/// for the next move too.
package struct OwedFocus<Spot: Hashable> {
    /// The card owed the focus, if any.
    package private(set) var spot: Spot?
    private var moves = 0

    package init() {}

    /// This card is owed the focus, for this move, which it names.
    package mutating func owe(_ spot: Spot) -> Int {
        moves += 1
        self.spot = spot
        return moves
    }

    /// The card took it.
    package mutating func took(_ spot: Spot) {
        if self.spot == spot { self.spot = nil }
    }

    /// This move's wait for its card to be drawn anew ended: should it not have been, as when nothing changed, it isn't
    /// owed the focus later. Unless a later move owes it anew.
    package mutating func waitEnded(_ move: Int) {
        if move == moves { spot = nil }
    }
}

/// A card a key, or a drop, takes to another column while it has the keyboard's focus, until it has the focus back there.
/// As its old place goes from the board, SwiftUI lets go of the focus and AppKit gives it to the next card by itself, in
/// one change, from the moved card to the next or from none, or in two, to none, then to the next: that card, which you
/// didn't choose, is where the moved card takes it back from as it's drawn anew (`OrderBoardView.mayTakeFocus(from:to:)`).
/// A work item's card goes once Azure DevOps has its new state, or as Copilot's work moves it before then, so you may
/// well have gone elsewhere meanwhile: only the focus going to a card right as its old place goes counts.
package struct MovingFocus<Spot: Hashable>: Equatable {
    package var spot: Spot
    /// Its move, as `OwedFocus` counts them: once that move's wait ends, it's done with.
    package var move: Int
    /// Its old place went from the board.
    package var left = false
    /// It lost the focus to none, as SwiftUI lets go of it as its old place goes, in a change of its own: you were on no
    /// card since, though the focus goes to the next card by itself.
    package private(set) var dropped = false
    /// The card AppKit gave the focus to as it went.
    package private(set) var handedOn: Spot?

    package init(spot: Spot, move: Int) {
        self.spot = spot
        self.move = move
    }

    /// As the keyboard's focus goes from one card to another, or to none: done with, once it has it back where it went,
    /// not while its old place is still there, as a work item's waits for Azure DevOps; the card the focus went to by
    /// itself, where it went from no card right as its old place went while you were last on it, or on none since it let
    /// go of it, as a click on a card says where you were last first; done with too, once you went on from that one.
    /// - Parameter last: the card you were last on, before this change.
    package func focusChanged(from old: Spot?, to new: Spot?, last: Spot?) -> MovingFocus? {
        if new == spot { return left ? nil : self }
        if old == spot, new == nil {
            var dropped = self
            dropped.dropped = true
            return dropped
        }
        if let new, left, handedOn == nil, old == nil || old == spot, last == spot || dropped && last == nil {
            var handed = self
            handed.handedOn = new
            return handed
        }
        return handedOn == nil || new == handedOn ? self : nil
    }
}
