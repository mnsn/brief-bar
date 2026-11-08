import BriefBarCore

/// What the Board's moves do, with the board and the stages as they are now: the card that a drop, ⌘→ or ⌘← acts on, looked
/// up again as it is now rather than as it was when you started dragging it, in the lane it's moved in where that lane has
/// it; and what moving it to a column of that lane does (`BoardRules`), with whether it's yours, and who opened it, as its
/// source tells.
@MainActor
package struct BoardMoves {
    let board: PullRequestBoard
    /// The missions the page shows, for whether a card can be set as next to merge.
    let missions: [OrderMission]
    let order: PullRequestOrder
    /// You can change missions yourself: Waits onto Can merge sets it as next to merge.
    let missionChanges: Bool

    package init(board: PullRequestBoard, missions: [OrderMission], order: PullRequestOrder, missionChanges: Bool) {
        self.board = board
        self.missions = missions
        self.order = order
        self.missionChanges = missionChanges
    }

    /// A pull request's card as the board has it now: in this lane, where it has it, else in its own; nil once it left the
    /// board.
    package func card(_ ref: ItemRef, in lane: BoardLane.Kind) -> BoardCard? {
        board.card(ref, preferring: lane)
    }

    /// What moving a card to a column of a lane does: only in its own lane, where it's yours to move.
    package func move(_ card: BoardCard, to stage: PullRequestStage, in lane: BoardLane.Kind) -> BoardMove {
        let sameLane = lane == .all || board.lanes.first { $0.kind == lane }?.cards.contains { $0.ref == card.ref } == true
        return BoardRules.move(
            card, to: stage, sameLane: sameLane, isYours: order.isYours(card.ref), author: order.author(of: card.ref),
            missionChanges: missionChanges, missions: missions.filter { $0.contains(card.ref) }, names: order.names,
            nextIn: stage == .canMerge ? nextHolding(card.ref) : nil
        )
    }

    /// The mission you set a pull request as next to merge in, by a change that holds, whose order puts it after one
    /// BriefBar hasn't seen merge: were it next in another, it would wait there again.
    private func nextHolding(_ ref: ItemRef) -> MissionKey? {
        guard let change = order.changes[ref], change.holds(in: order.orders), case .plan(let id)? = change.first,
              let after = order.orders.plan(id)?.entry(for: ref)?.after
        else { return nil }
        let merged = Set(order.missions.flatMap { $0.steps + $0.attached }.filter { $0.status == .merged }.map(\.ref))
        return after.contains { !merged.contains($0) && !change.notAfter.contains($0) } ? change.first : nil
    }

    /// What dropping what a drag carries on a column of a lane does, to the card as it is now: nil for anything but this
    /// board's drag, such as text from another app that names a pull request, and for a card that left the board meanwhile.
    package func drop(_ payload: String, of drag: BoardDrag?, on stage: PullRequestStage, in lane: BoardLane.Kind)
        -> (card: BoardCard, move: BoardMove)? {
        guard let ref = drag?.ref(dropped: payload), let card = card(ref, in: lane) else { return nil }
        return (card, move(card, to: stage, in: lane))
    }

    /// What ⌘→ or ⌘← does to a card of a lane, as it is now: nil at either end of the columns, or once it left the board.
    package func key(_ ref: ItemRef, in lane: BoardLane.Kind, forward: Bool) -> (card: BoardCard, move: BoardMove)? {
        guard let card = card(ref, in: lane), let stage = BoardRules.keyTarget(from: card.stage, forward: forward) else { return nil }
        return (card, move(card, to: stage, in: lane))
    }
}
