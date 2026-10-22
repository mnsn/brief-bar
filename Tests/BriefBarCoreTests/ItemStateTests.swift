import Foundation
import Testing
@testable import BriefBarCore

@Suite struct ItemStateTests {
    /// A source's own groups, as they'd map onto the shared states.
    private enum Group: CaseIterable {
        case asks, waits, broke, works, finished, hidden

        var state: ItemState? {
            switch self {
            case .asks, .waits: return .needsYou
            case .broke: return .failing
            case .works: return .running
            case .finished: return .done
            case .hidden: return nil
            }
        }
    }

    @Test func addsEachGroupToItsStateAndLeavesOutGroupsWithNone() {
        let counts: [Group: Int] = [.asks: 2, .waits: 1, .broke: 3, .works: 4, .finished: 5, .hidden: 100]
        let states = StateCounts(Group.allCases, count: { counts[$0] ?? 0 }, state: \.state)
        #expect(states == StateCounts(needsYou: 3, failing: 3, running: 4, done: 5))
        #expect(ItemState.allCases.map { states[$0] } == [3, 3, 4, 5])
        #expect(states.total == 15)
        #expect(StateCounts().total == 0)
    }

    @Test func addsUpSections() {
        let chats = StateCounts(needsYou: 2)
        let pullRequests = StateCounts(needsYou: 3, failing: 2, done: 2)
        let sessions = StateCounts(needsYou: 3, failing: 1, running: 2, done: 1)
        #expect(chats + pullRequests + sessions == StateCounts(needsYou: 8, failing: 3, running: 2, done: 3))

        var sum = StateCounts()
        sum += sessions
        sum[.running] += 1
        #expect(sum == StateCounts(needsYou: 3, failing: 1, running: 3, done: 1))
    }

    @Test func printsEveryStateByName() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try #require(String(data: encoder.encode(StateCounts(needsYou: 1, done: 2)), encoding: .utf8))
        #expect(json == #"{"done":2,"failing":0,"needsYou":1,"running":0}"#)
        #expect(ItemState.allCases.map(\.rawValue) == ["needsYou", "failing", "running", "done"])
    }
}
