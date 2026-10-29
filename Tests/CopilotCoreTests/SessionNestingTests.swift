import Foundation
import Testing
@testable import CopilotCore

private func snapshot(_ id: String, _ phase: DisplayPhase, since seconds: TimeInterval) -> SessionSnapshot {
    let reason: StatusReason = phase == .needsYou ? .question : .working
    return SessionSnapshot(
        id: id, name: id.capitalized, projectName: nil, branch: nil, isChat: false, mode: nil, phase: phase, reason: reason,
        headline: reason.headline, detail: nil, choices: [], since: t(seconds)
    )
}

/// The snapshots as the list sorts them, then nested by the parents the app records.
private func nested(_ snapshots: [SessionSnapshot], parents: [String: String]) -> [SessionSnapshot] {
    let records = snapshots.map { SessionRecord(meta: SessionMeta(id: $0.id, name: $0.name, parentSessionId: parents[$0.id]), log: nil) }
    return SessionNesting.nest(SessionOrdering.sorted(snapshots), records: records)
}

/// Each session's ID, indented as deep as it's nested.
private func outline(_ snapshots: [SessionSnapshot]) -> [String] {
    snapshots.map { String(repeating: "  ", count: $0.depth) + $0.id }
}

@Suite struct SessionNestingTests {
    /// The most recent first, in Running; a family goes where its most recent member would.
    @Test func nestsSessionsUnderTheirParentsInTheSameGroup() {
        let snapshots = [
            snapshot("lead", .running, since: 0), snapshot("other", .running, since: 10),
            snapshot("child", .running, since: 20), snapshot("grandchild", .running, since: 5),
        ]
        #expect(outline(SessionOrdering.sorted(snapshots)) == ["child", "other", "grandchild", "lead"])

        let sessions = nested(snapshots, parents: ["child": "lead", "grandchild": "child"])
        #expect(outline(sessions) == ["lead", "  child", "    grandchild", "other"])
        #expect(sessions.map(\.parent) == [
            nil, RelatedSession(id: "lead", name: "Lead"), RelatedSession(id: "child", name: "Child"), nil,
        ])
        #expect(PhaseCounts(sessions) == PhaseCounts(snapshots))
    }

    /// The longest wait first, in Needs You: a parent comes first, then its children, the longest-waiting first.
    @Test func aFamilyTakesThePlaceOfItsFirstMember() {
        let snapshots = [
            snapshot("other", .needsYou, since: 10), snapshot("lead", .needsYou, since: 30),
            snapshot("first", .needsYou, since: 0), snapshot("second", .needsYou, since: 20),
        ]
        #expect(outline(SessionOrdering.sorted(snapshots)) == ["first", "other", "second", "lead"])
        #expect(outline(nested(snapshots, parents: ["first": "lead", "second": "lead"])) == [
            "lead", "  first", "  second", "other",
        ])
    }

    /// A session whose parent is in another group stays where it was, and knows its parent, for its tag.
    @Test func aSessionWhoseParentIsInAnotherGroupStaysInItsPlace() {
        let snapshots = [
            snapshot("child", .needsYou, since: 0), snapshot("other", .needsYou, since: 10),
            snapshot("busy", .running, since: 30), snapshot("lead", .running, since: 5),
        ]
        let sessions = nested(snapshots, parents: ["child": "lead"])
        #expect(outline(sessions) == ["child", "other", "busy", "lead"])
        #expect(sessions[0].parent == RelatedSession(id: "lead", name: "Lead"))
        #expect(sessions.dropFirst().allSatisfy { $0.parent == nil })
    }

    /// One whose parent isn't listed, such as one archived, isn't nested or tagged.
    @Test func aParentThatIsntListedChangesNothing() {
        let snapshots = [snapshot("child", .running, since: 10), snapshot("other", .running, since: 0)]
        let sorted = SessionOrdering.sorted(snapshots)
        #expect(nested(snapshots, parents: ["child": "archived"]) == sorted)
        #expect(nested(snapshots, parents: ["child": "child"]) == sorted)
        #expect(nested(snapshots, parents: [:]) == sorted)
    }

    /// Sessions recorded as each other's parents are all still listed: the one that sorts first heads them.
    @Test func keepsSessionsRecordedAsEachOthersParents() {
        let snapshots = [
            snapshot("a", .running, since: 10), snapshot("b", .running, since: 5), snapshot("c", .running, since: 20),
        ]
        let sessions = nested(snapshots, parents: ["a": "b", "b": "c", "c": "a"])
        #expect(outline(sessions) == ["c", "  b", "    a"])
        #expect(sessions.allSatisfy { $0.parent != nil })
    }

    /// Two snapshots with one ID, which a list never has, can't be told apart: nothing is nested.
    @Test func leavesAListWithRepeatedIDsAsItIs() {
        let snapshots = [snapshot("lead", .running, since: 0), snapshot("child", .running, since: 10), snapshot("child", .idle, since: 5)]
        let records = [SessionRecord(meta: SessionMeta(id: "child", name: "Child", parentSessionId: "lead"), log: nil)]
        #expect(SessionNesting.nest(snapshots, records: records) == snapshots)
    }
}
