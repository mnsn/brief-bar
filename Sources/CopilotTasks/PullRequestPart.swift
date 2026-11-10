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
    /// The Push & Reply that took it on fixed it first: a comment's Fix, or Fix All, sent with Push and Reply on, which
    /// fixes the threads it takes on, then commits, pushes and replies on them. Nil otherwise, as for what BriefBar kept
    /// before it had this, which a build that doesn't know it takes for what a Push & Reply took on.
    public var fixes: Bool?
    /// For the conflicts, the pull request's target branch as it took them on: with another, they're other conflicts. Nil
    /// for the rest, and for conflicts BriefBar kept before it had this.
    public var target: String?
    /// For a Push & Reply that fixed it first (`fixes`), the commit the pull request's branch was at as it was sent, as
    /// BriefBar's list had read it: once the task finished, it pushed only if the list reads another since, since its
    /// prompt has it stop before it pushes, as when the tests don't pass. Nil otherwise, when the list didn't have it, and
    /// for what BriefBar kept before it had this.
    public var head: String?
    /// Once a task that took it on was gone on with (`ended`): by when it was over, as the first task that went on with its
    /// session started, whichever goes on since; a fork of the session made after that has it. Nil until then, and for what
    /// BriefBar kept before it had this.
    public var overBy: Date?

    public init(
        _ part: PullRequestPart, since: Date, ended: RunPhase? = nil, ships: Bool? = nil, fixes: Bool? = nil, target: String? = nil,
        head: String? = nil, overBy: Date? = nil
    ) {
        self.part = part
        self.since = since
        self.ended = ended
        self.ships = ships
        self.fixes = fixes
        self.target = target
        self.head = head
        self.overBy = overBy
    }
}

/// A Push & Reply that ran in a task's session before it, on the same pull request (`CopilotRun.pushes`): when it started,
/// and how it ended. It committed and pushed all that the session had changed by then, whatever its prompt listed; one
/// that fixed what it took on first (`fixes`), as a comment's Fix sent with Push and Reply on, only if the pull request's
/// branch moved from `head` since, as BriefBar's list reads it.
public struct SessionPush: Sendable, Codable, Equatable, Hashable {
    public var since: Date
    public var ended: RunPhase
    /// It fixed what it took on first (`TakenPart.fixes`). Nil otherwise, and for what BriefBar kept before it had this.
    public var fixes: Bool?
    /// For one that fixed what it took on first, the commit the pull request's branch was at as it was sent
    /// (`TakenPart.head`).
    public var head: String?

    public init(since: Date, ended: RunPhase, fixes: Bool? = nil, head: String? = nil) {
        self.since = since
        self.ended = ended
        self.fixes = fixes
        self.head = head
    }
}
