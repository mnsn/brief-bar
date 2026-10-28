import Foundation

/// What the Copilot CLI has of BriefBar's, its MCP server or its plugin, as the Agents page shows it, while BriefBar's
/// checks and changes reach the CLI one at a time, in the order they were asked for: working until the last one asked for
/// is done, and then what the CLI said to that one. What an earlier one found doesn't show while a later one is still to
/// come, so that a check that ends while turning agents off is on its way isn't taken for what turning them off left.
public struct CopilotCLIProgress<Status: Sendable & Equatable>: Sendable, Equatable {
    /// What the CLI said to the last one asked for, once it was done; nil before any was.
    public private(set) var status: Status?
    private var asked = 0
    private var done = 0

    public init(status: Status? = nil) {
        self.status = status
    }

    /// A check or a change is under way, or waiting its turn.
    public var isWorking: Bool { done < asked }

    /// Asks for a check or a change: its number, to answer it by.
    public mutating func ask() -> Int {
        asked += 1
        return asked
    }

    /// What the CLI said to the one with this number, which shows only if it's the last one asked for.
    public mutating func answer(_ number: Int, with status: Status) {
        done = max(done, number)
        if number == asked { self.status = status }
    }
}
