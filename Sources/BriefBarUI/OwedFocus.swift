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
