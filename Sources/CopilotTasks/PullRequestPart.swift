import Foundation

/// Something of a pull request that Copilot takes on, by its ID, never what it says: one of its comment threads, one of
/// its builds, or its merge conflicts. What BriefBar keeps of a task (`CopilotRun.taken`), and of a prompt sent to a
/// session, so that each can say what became of it.
public enum PullRequestPart: Sendable, Hashable, Codable {
    /// A comment thread, by its ID, which is its pull request's own.
    case thread(Int)
    /// A build that validates it, by its pipeline, the build definition's ID: each of its runs, as it runs again or after a
    /// push, is the same build.
    case build(Int)
    /// Its merge conflicts with its target branch.
    case conflicts

    /// The thread's ID, for a thread.
    public var thread: Int? {
        if case .thread(let id) = self { id } else { nil }
    }

    /// The pipeline's ID, for a build.
    public var build: Int? {
        if case .build(let id) = self { id } else { nil }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id
    }

    private enum Kind: String, Codable {
        case thread, build, conflicts
    }

    /// Checked as when it was made, by its kind and ID: any program running as you can write the preferences.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .thread: self = .thread(try container.decode(Int.self, forKey: .id))
        case .build: self = .build(try container.decode(Int.self, forKey: .id))
        case .conflicts: self = .conflicts
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .thread(let id):
            try container.encode(Kind.thread, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .build(let id):
            try container.encode(Kind.build, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .conflicts:
            try container.encode(Kind.conflicts, forKey: .kind)
        }
    }
}

/// Something of the pull request a task took on (`CopilotRun.taken`): by its ID, never what it says, with when, what for,
/// and how the task that took it on ended, once a later task went on with the same session.
public struct TakenPart: Sendable, Codable, Equatable, Hashable {
    public var part: PullRequestPart
    /// When the task that took it on started.
    public var since: Date
    /// How that task ended, once a later one went on with its session; nil while it's the session's latest.
    public var ended: RunPhase?
    /// A Push & Reply took it on, to push its fix, and, for a thread its prompt listed, to reply on it; nil for a fix.
    public var ships: Bool?

    public init(_ part: PullRequestPart, since: Date, ended: RunPhase? = nil, ships: Bool? = nil) {
        self.part = part
        self.since = since
        self.ended = ended
        self.ships = ships
    }
}
