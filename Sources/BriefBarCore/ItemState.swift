import Foundation

/// What something a source shows means for you, the same for every source: a chat, a pull request, a Copilot
/// session or a pipeline. Each source maps its own groups onto these, so that a menu-bar item can add up its
/// sections' counts by state: 2 unread chats and 3 pull requests that need you make ✋ 5. What a source doesn't
/// count in the menu bar, such as a pull request waiting on others or an idle session, has no state.
public enum ItemState: String, CaseIterable, Codable, Sendable {
    /// ✋ Waits for you: an unread chat, a pull request with something new for you, a Copilot session's question,
    /// plan or permission prompt.
    case needsYou
    /// ✕ Something's wrong: a failing pull request, a failed pipeline, a Copilot session that stopped.
    case failing
    /// ⚡ At work: a Copilot session that's running, a pipeline that's running or queued.
    case running
    /// ✓ Done or ready: a pull request that's ready to complete, a Copilot session that finished.
    case done
}

/// How many things are in each state: a section's, or the sum of several sections'.
public struct StateCounts: Sendable, Equatable, Codable {
    public var needsYou = 0
    public var failing = 0
    public var running = 0
    public var done = 0

    public init(needsYou: Int = 0, failing: Int = 0, running: Int = 0, done: Int = 0) {
        self.needsYou = needsYou
        self.failing = failing
        self.running = running
        self.done = done
    }

    /// A source's counts of its own groups, each added to the state it maps to. Groups with no state aren't
    /// counted.
    public init<Group>(_ groups: some Sequence<Group>, count: (Group) -> Int, state: (Group) -> ItemState?) {
        for group in groups {
            if let state = state(group) {
                self[state] += count(group)
            }
        }
    }

    public subscript(state: ItemState) -> Int {
        get {
            switch state {
            case .needsYou: return needsYou
            case .failing: return failing
            case .running: return running
            case .done: return done
            }
        }
        set {
            switch state {
            case .needsYou: needsYou = newValue
            case .failing: failing = newValue
            case .running: running = newValue
            case .done: done = newValue
            }
        }
    }

    /// Everything counted, in any state.
    public var total: Int { ItemState.allCases.map { self[$0] }.reduce(0, +) }

    public static func + (lhs: StateCounts, rhs: StateCounts) -> StateCounts {
        var sum = lhs
        sum += rhs
        return sum
    }

    public static func += (lhs: inout StateCounts, rhs: StateCounts) {
        for state in ItemState.allCases {
            lhs[state] += rhs[state]
        }
    }
}
