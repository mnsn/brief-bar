import Foundation

// Whether one of a mission's pull requests can merge first, ahead of what its order puts before it, as Set as Next to Merge
// would have it: not while it's stacked on one BriefBar hasn't seen merge, which only retargeting it in its source changes,
// nor while it still targets the branch of one that merged. One answer for Mission ▸ Set as Next to Merge and for the
// Board's Waits onto Can merge, so they agree, and say the same.

extension OrderMission {
    /// The pull requests one of its own is stacked on that BriefBar hasn't seen merge, the nearest first: by what goes
    /// before it in its order, whatever its order names first; by how it's stacked with the order's pull requests when the
    /// order doesn't name it; by what BriefBar sees that the order doesn't say; and by the branch its changes show against.
    public func stackedBases(of ref: ItemRef) -> [ItemRef] {
        guard let step = (steps + attached).first(where: { $0.ref == ref }) else { return [] }
        var statuses: [ItemRef: OrderStatus] = [:]
        for other in steps + attached { statuses[other.ref] = other.status }
        for prerequisite in step.prerequisites where statuses[prerequisite.ref] == nil {
            statuses[prerequisite.ref] = prerequisite.status
        }
        var bases: [ItemRef] = []
        func add(_ other: ItemRef) {
            guard other != ref, statuses[other] != .merged, !bases.contains(other) else { return }
            bases.append(other)
        }
        for prerequisite in step.prerequisites where prerequisite.origins.contains(where: \.isStacked) {
            add(prerequisite.ref)
        }
        for note in step.notes {
            switch note {
            case .stackedWith(let other, true, _), .showsAgainst(let other):
                add(other)
            case .orderDisagrees(let other, let origin) where origin.isStacked:
                add(other)
            default:
                break
            }
        }
        // The nearest first: the one it comes right after.
        return bases.filter { step.directPrerequisites.contains($0) } + bases.filter { !step.directPrerequisites.contains($0) }
    }

    /// What stops one of its pull requests from being set as next to merge, as Set as Next to Merge refuses it: it still
    /// targets the branch of one that merged, as its standing says, or a branch it targets that merged says, whatever its
    /// standing says first; or it's stacked on one BriefBar hasn't seen merge, the nearest. Nil when nothing does.
    public func notNext(_ ref: ItemRef) -> OrderChangeError? {
        guard let step = (steps + attached).first(where: { $0.ref == ref }) else { return nil }
        if let (merged, branch) = OrderChanges.retarget(of: step) { return .retarget(after: merged, to: branch) }
        return stackedBases(of: ref).first.map { .stacked(on: $0) }
    }

    /// Why one of its pull requests can't be set as next to merge: "Stacked on !4102: retarget it in Azure DevOps first",
    /// or, still targeting the branch of one that merged, "!4102 merged: retarget it to main"; nil when nothing stops it.
    public func whyNotNext(_ ref: ItemRef) -> String? {
        notNext(ref)?.description
    }
}
