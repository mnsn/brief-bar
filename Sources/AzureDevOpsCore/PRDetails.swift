import Foundation

/// What a pull request's policies and threads say, fetched separately from the list (two requests).
public struct PRDetails: Sendable, Codable, Equatable {
    public var fetchedAt: Date
    /// The pull request's fingerprint when these were fetched.
    public var fingerprint: String
    public var checks: [Check]
    /// False when the project doesn't let you read its policies: then nobody can tell whether the pull
    /// request is ready, and `checks` is empty.
    public var checksKnown: Bool
    /// Conversations between people: system threads and deleted comments are left out.
    public var threads: [ReviewThread]
    /// Pushes, votes and reviewer changes, from the system threads.
    public var activity: [Activity]
    /// The latest comment, push, vote or other change.
    public var lastActivity: Date?

    public init(
        fetchedAt: Date, fingerprint: String, checks: [Check] = [], checksKnown: Bool = true, threads: [ReviewThread] = [],
        activity: [Activity] = [], lastActivity: Date? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.fingerprint = fingerprint
        self.checks = checks
        self.checksKnown = checksKnown
        self.threads = threads
        self.activity = activity
        self.lastActivity = lastActivity
    }

    /// `evaluations` is nil when the policies couldn't be read.
    public init(fetchedAt: Date, pullRequest: PullRequest, evaluations: [ADOPolicyEvaluation]?, threads: [ADOThread]) {
        let names = Self.names(of: pullRequest)

        var reviewThreads: [ReviewThread] = []
        var activity: [Activity] = []
        var latest: Date?
        for thread in threads where thread.isDeleted != true {
            for date in [thread.publishedDate, thread.lastUpdatedDate].compactMap({ $0 }) {
                latest = max(latest ?? date, date)
            }
            if let kind = thread.activityType {
                if let item = Activity(thread, type: kind) { activity.append(item) }
            } else if let item = ReviewThread(thread, names: names) {
                reviewThreads.append(item)
                for comment in item.comments { latest = max(latest ?? comment.publishedAt, comment.publishedAt) }
            }
        }
        self.init(
            fetchedAt: fetchedAt,
            fingerprint: pullRequest.fingerprint,
            checks: evaluations?.compactMap(Check.init) ?? [],
            checksKnown: evaluations != nil,
            threads: reviewThreads,
            activity: activity.sorted { $0.at < $1.at },
            lastActivity: latest
        )
    }

    /// Whether a check is still going, so the details are worth refreshing more often.
    public var hasChecksInProgress: Bool {
        checks.contains { $0.isBlocking && ($0.state == .running || $0.state == .queued) }
    }

    /// The names of the pull request's people, its reviewers and its author, by their lowercased IDs, for mentions in its
    /// comments to say.
    static func names(of pullRequest: PullRequest) -> [String: String] {
        var names: [String: String] = [:]
        for reviewer in pullRequest.reviewers { names[reviewer.person.id] = reviewer.person.name }
        names[pullRequest.author.id] = pullRequest.author.name
        return names
    }
}

/// One branch policy on the pull request, simplified.
public struct Check: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// A build validation pipeline.
        case build
        /// A status posted by an external service.
        case status
        /// Minimum reviewers, required reviewers and similar sign-offs.
        case reviewers
        /// Things the author has to do, such as linking a work item or resolving comments.
        case requirement
        /// Checked when the pull request is completed (the merge strategy), so it doesn't block readiness.
        case completion
    }

    public enum State: String, Sendable, Codable {
        case passed, failed, running, queued
        /// A build that passed but is too old (or the target branch moved): it has to run again.
        case expired
        /// A build that hasn't run at all, for example because it has to be queued by hand.
        case notRun
        /// Waiting for something other than a build: approvals, a status, the author.
        case pending
        case notApplicable
    }

    public var name: String
    public var kind: Kind
    public var state: State
    public var isBlocking: Bool
    /// How many approvals a minimum-reviewers policy wants.
    public var minimumApprovers: Int?
    public var completedAt: Date?
    /// The run a build policy queued, in the pull request's project.
    public var buildId: Int?
    /// The pipeline a build policy runs, its build definition's ID, which each of its runs shares; nil when the policy
    /// doesn't say.
    public var definitionId: Int?
    /// Where that build failed, and the first error there, once its timeline has been read.
    public var failure: PipelineFailure?
    /// For a build that expired, how it stood before: failed, for a rejected or broken one, which is still to fix, not only
    /// to queue again; nil for one that passed, or when Azure DevOps doesn't say.
    public var expiredFrom: State?
    /// Lowercased identity IDs of the people and teams a required-reviewers policy requires; empty when it doesn't say.
    public var reviewerIds: [String]

    public init(
        name: String, kind: Kind, state: State, isBlocking: Bool = true, minimumApprovers: Int? = nil, completedAt: Date? = nil,
        buildId: Int? = nil, definitionId: Int? = nil, failure: PipelineFailure? = nil, reviewerIds: [String] = [],
        expiredFrom: State? = nil
    ) {
        self.name = name
        self.kind = kind
        self.state = state
        self.isBlocking = isBlocking
        self.minimumApprovers = minimumApprovers
        self.completedAt = completedAt
        self.buildId = buildId
        self.definitionId = definitionId
        self.failure = failure
        self.reviewerIds = reviewerIds.map { $0.lowercased() }
        self.expiredFrom = expiredFrom
    }

    /// Nil for a disabled policy.
    public init?(_ evaluation: ADOPolicyEvaluation) {
        let configuration = evaluation.configuration
        guard configuration.isEnabled != false else { return nil }
        let type = configuration.type.displayName
        let settings = configuration.settings
        let context = evaluation.context
        let status = evaluation.status ?? "queued"

        switch type {
        case "Build":
            kind = .build
            name = Self.nonEmpty(settings?.displayName) ?? Self.nonEmpty(context?.buildDefinitionName) ?? "Build"
            switch status {
            case "approved": state = .passed
            case "rejected", "broken":
                state = context?.isExpired == true ? .expired : .failed
                if state == .expired { expiredFrom = .failed }
            case "running": state = .running
            case "notApplicable": state = .notApplicable
            default:
                // Queued: an expired build waits to be queued again; one without a build never ran.
                if context?.isExpired == true {
                    state = .expired
                } else if context?.buildId == nil {
                    state = .notRun
                } else {
                    state = .queued
                }
            }
        case "Status":
            kind = .status
            let genre = settings?.statusGenre.map { $0.isEmpty ? "" : "\($0)/" } ?? ""
            name = Self.nonEmpty(settings?.defaultDisplayName)
                ?? Self.nonEmpty(settings?.statusName).map { genre + $0 }
                ?? "Status check"
            switch status {
            case "approved": state = .passed
            case "rejected", "broken": state = .failed
            case "running": state = .running
            case "notApplicable": state = .notApplicable
            default: state = .pending
            }
        default:
            name = type
            switch type {
            case "Minimum number of reviewers", "Required reviewers", "Proof Of Presence": kind = .reviewers
            case "Require a merge strategy": kind = .completion
            default: kind = .requirement
            }
            switch status {
            case "approved": state = .passed
            case "notApplicable": state = .notApplicable
            // A requirement that isn't met yet is reported as rejected; it's pending, not failed.
            default: state = .pending
            }
        }
        isBlocking = configuration.isBlocking ?? true
        minimumApprovers = settings?.minimumApproverCount
        completedAt = evaluation.completedDate
        buildId = kind == .build ? context?.buildId : nil
        definitionId = kind == .build ? settings?.buildDefinitionId ?? context?.buildDefinitionId : nil
        reviewerIds = kind == .reviewers ? (settings?.requiredReviewerIds ?? []).map { $0.lowercased() } : []
    }

    /// A build that failed, and whose run is known: its timeline says where.
    var failedBuildId: Int? {
        kind == .build && state == .failed ? buildId : nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}

/// A conversation on the pull request, general or on a line of code.
public struct ReviewThread: Sendable, Codable, Equatable {
    public var id: Int
    /// `active`, `pending`, `fixed`, `wontFix`, `closed`, `byDesign`, or nil.
    public var status: String?
    public var filePath: String?
    public var line: Int?
    public var comments: [ReviewComment]
    /// Where on its file it is, in full: its lines on each side of the diff, and which diff. Nil for a thread that isn't
    /// on a file.
    public var location: Location?

    public init(
        id: Int, status: String? = "active", filePath: String? = nil, line: Int? = nil, comments: [ReviewComment],
        location: Location? = nil
    ) {
        self.id = id
        self.status = status
        self.filePath = filePath
        self.line = line
        self.comments = comments
        self.location = location
    }

    /// Nil when nothing is left once system and deleted comments are removed.
    init?(_ thread: ADOThread, names: [String: String]) {
        var names = names
        for identity in (thread.identities ?? [:]).values {
            names[identity.id.lowercased()] = identity.displayName
        }
        for comment in thread.comments ?? [] {
            if let author = comment.author { names[author.id.lowercased()] = author.displayName }
        }
        let comments = (thread.comments ?? []).compactMap { ReviewComment($0, names: names, published: thread.publishedDate) }
        guard !comments.isEmpty else { return nil }
        self.init(
            id: thread.id,
            status: thread.status,
            filePath: thread.threadContext?.filePath,
            line: thread.threadContext?.rightFileStart?.line ?? thread.threadContext?.leftFileStart?.line,
            comments: comments.sorted { $0.publishedAt < $1.publishedAt },
            location: Location(thread.threadContext, thread.pullRequestThreadContext)
        )
    }

    /// Resolved one way or another: fixed, won't fix, closed or by design.
    public var isResolved: Bool {
        guard let status else { return false }
        return !["active", "pending", "unknown"].contains(status)
    }

    /// "Program.cs" for a thread on a line of code.
    public var fileName: String? {
        filePath.map { ($0 as NSString).lastPathComponent }
    }
}

public struct ReviewComment: Sendable, Codable, Equatable {
    public var id: Int
    public var author: Person
    /// Plain text: markdown and HTML removed, mentions shown as names.
    public var text: String
    /// All of it, as its author wrote it, in Markdown, with each mention as a name ("@Sam Rivera"), to show with
    /// `RichText(markdown:)`.
    public var markdown: String
    /// Lowercased IDs of the people it @mentions.
    public var mentions: [String]
    public var publishedAt: Date
    /// All of it as Azure DevOps keeps it, each mention as its ID (`@<…>`), to tell a reply of yours that went from one to
    /// send, and to edit one: nil for one made up, as the demo's.
    public var content: String?
    /// When its author last changed what it says, once that's after it was published: nil for one never edited, or when
    /// Azure DevOps doesn't say.
    public var editedAt: Date?
    /// What kind of comment Azure DevOps says it is, `text`, what someone wrote, or `codeChange`; nil when it doesn't say,
    /// as for the demo's. System comments are never read.
    public var commentType: String?
    /// The names its mentions show as (`markdown`), by their lowercased IDs, as BriefBar named them as it read it: from the
    /// pull request's people, and its thread's identities and comments' authors, those it leaves out too; for your edit of
    /// it to name them the same (`CommentEditing`). Empty for one made up, as the demo's, whose mentions are names already.
    public var mentionNames: [String: String]

    /// `markdown` is `text` unless it's given.
    public init(
        id: Int, author: Person, text: String, markdown: String? = nil, mentions: [String] = [], publishedAt: Date, content: String? = nil,
        editedAt: Date? = nil, commentType: String? = nil, mentionNames: [String: String] = [:]
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.markdown = markdown ?? text
        self.mentions = mentions.map { $0.lowercased() }
        self.publishedAt = publishedAt
        self.content = content
        self.editedAt = editedAt
        self.commentType = commentType
        self.mentionNames = mentionNames
    }

    /// Nil for a deleted or system comment, or one without an author or anything to say.
    /// - Parameters:
    ///   - names: names by lowercased IDs, for its mentions.
    ///   - published: when its thread was, for a comment that doesn't say when it was.
    init?(_ comment: ADOComment, names: [String: String], published: Date?) {
        guard comment.isDeleted != true, comment.commentType != "system", let author = comment.author,
              let content = comment.content, !content.isEmpty
        else { return nil }
        let publishedAt = comment.publishedDate ?? published ?? .distantPast
        let mentions = CommentText.mentionedIds(content)
        self.init(
            id: comment.id,
            author: Person(author),
            text: CommentText.plain(content, names: names),
            markdown: CommentText.naming(content, names: names),
            mentions: mentions,
            publishedAt: publishedAt,
            content: content,
            // Azure DevOps dates what it says as it publishes it, then each time its author edits it: a second after, and it
            // was edited.
            editedAt: comment.lastContentUpdatedDate.flatMap { $0.timeIntervalSince(publishedAt) > 1 ? $0 : nil },
            commentType: comment.commentType,
            mentionNames: names.filter { mentions.contains($0.key) }
        )
    }

    /// What it says, as Azure DevOps keeps it, or, for one made up, as it shows: two that say the same are the same comment
    /// as edited.
    public var kept: String { content ?? markdown }

    /// Whether you may edit or delete it from BriefBar: it's yours, as `me`, the identity the list was read as, says, and what
    /// someone wrote, rather than a code change's comment. Neither a deleted comment nor a system one is ever read.
    public func isEditable(by me: String?) -> Bool {
        guard let me, author.id == me.lowercased() else { return false }
        return commentType == nil || commentType == "text"
    }
}

/// Something that happened on the pull request, recorded by Azure DevOps as a system thread.
public struct Activity: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// New commits were pushed.
        case push
        case vote
        case reviewersChanged
        /// A push reset the reviewers' votes.
        case votesReset
        case draftChanged
        case autoComplete
        case other
    }

    public var threadId: Int
    public var kind: Kind
    public var at: Date
    public var actor: Person?
    public var vote: Vote?
    public var commitCount: Int?
    /// Lowercased IDs of reviewers added.
    public var added: [String]

    public init(threadId: Int, kind: Kind, at: Date, actor: Person? = nil, vote: Vote? = nil, commitCount: Int? = nil, added: [String] = []) {
        self.threadId = threadId
        self.kind = kind
        self.at = at
        self.actor = actor
        self.vote = vote
        self.commitCount = commitCount
        self.added = added.map { $0.lowercased() }
    }

    init?(_ thread: ADOThread, type: String) {
        guard let at = thread.publishedDate ?? thread.comments?.first?.publishedDate else { return nil }
        var actor: ADOIdentity?
        var vote: Vote?
        var commitCount: Int?
        var added: [String] = []
        let kind: Kind
        switch type {
        case "RefUpdate":
            kind = .push
            actor = thread.identity(forProperty: "CodeReviewRefUpdatedByIdentity")
            commitCount = thread.properties?["CodeReviewRefNewCommitsCount"]?.value.flatMap { Int($0) }
        case "VoteUpdate":
            kind = .vote
            actor = thread.identity(forProperty: "CodeReviewVotedByIdentity")
            vote = Vote(thread.properties?["CodeReviewVoteResult"]?.value)
        case "ReviewersUpdate":
            kind = .reviewersChanged
            actor = thread.identity(forProperty: "CodeReviewReviewersUpdatedByIdentity")
            // One identity key, or several separated by commas.
            let keys = thread.properties?["CodeReviewReviewersUpdatedAddedIdentity"]?.value?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            added = keys.compactMap { thread.identities?[$0]?.id }
        case "ResetMultipleVotes", "ResetAllVotes":
            kind = .votesReset
        case "IsDraftUpdate":
            kind = .draftChanged
            actor = thread.identity(forProperty: "CodeReviewIsDraftUpdatedByIdentity")
        case "AutoCompleteUpdate":
            kind = .autoComplete
        default:
            kind = .other
        }
        self.init(threadId: thread.id, kind: kind, at: at, actor: actor.map(Person.init), vote: vote,
                  commitCount: commitCount, added: added)
    }
}

/// Turns a comment's markdown into one plain line for the panel.
public enum CommentText {
    /// Mentions look like `@<6B3C1F2A-...>` in the markdown.
    nonisolated(unsafe) static let mention = /@<([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})>/

    public static func mentionedIds(_ markdown: String) -> [String] {
        markdown.matches(of: mention).map { String($0.output.1).lowercased() }
    }

    public static func plain(_ markdown: String, names: [String: String], limit: Int = 500) -> String {
        var text = naming(markdown, names: names)
        // Code fences and HTML tags go; the text inside stays.
        text = text.replacing(/(?m)^\s*```.*$/, with: " ")
        text = text.replacing(/<[^>]{1,200}>/, with: " ")
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = PlainText.fromMarkdown(text)
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The markdown with each mention as a name, "@Sam Rivera", or "@someone" for one `names` doesn't have.
    static func naming(_ markdown: String, names: [String: String]) -> String {
        markdown.replacing(mention) { match in
            "@" + (names[String(match.output.1).lowercased()] ?? "someone")
        }
    }
}

/// Flattens markdown snippets into one readable line.
public enum PlainText {
    public static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func fromMarkdown(_ markdown: String) -> String {
        var text = markdown
        // Links, including one that's cut off.
        text = text.replacing(/!?\[([^\]]*)\]\([^)]*(\)|$)/) { String($0.output.1) }
        text = text.replacing(/(\*\*|__|`)/, with: "")
        text = text.replacing(/(?m)^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+)/, with: "")
        return singleLine(text)
    }
}
