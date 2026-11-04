import Foundation

/// The only changes BriefBar makes in Azure DevOps, each when you click it, with **Make Changes in Azure DevOps** on: your
/// reply in a pull request's comment thread, a thread's status, and a tag you add to a pull request or take off it. Every
/// other request BriefBar sends Azure DevOps is a GET
/// (`ADOClient.get`); these go only through `ADOClient.send(_:as:)`, which sends nothing else, with the same sign-in, to the same
/// host, following no redirect. Each is on a pull request (`pullRequest`), and a thread's on one of its threads (`thread`).
/// A change BriefBar comes to make later is another case here, and a kind of its own (`Kind`), which the tests go through.
public enum ADOWrite: Sendable, Equatable {
    /// Your comment in a thread, in reply to its first, in Markdown: `POST …/pullRequests/{id}/threads/{thread}/comments`.
    case reply(ThreadAddress, markdown: String, parentCommentId: Int)
    /// A thread's status, and nothing else of it: `PATCH …/pullRequests/{id}/threads/{thread}`.
    case setStatus(ThreadAddress, ThreadStatus)
    /// A tag on the pull request, by its name, which Azure DevOps calls a label: `POST …/pullRequests/{id}/labels`. It makes
    /// the project's tag too when the project has none of that name, and answers with the tag.
    case addTag(PullRequestAddress, name: String)
    /// A tag off the pull request, by the project's tag's ID, or else its name: `DELETE …/pullRequests/{id}/labels/{tag}`.
    /// The project keeps the tag.
    case removeTag(PullRequestAddress, tag: String)

    /// Each change BriefBar can make, apart from what it says: tests go through all of them, so a new one comes with its
    /// own.
    public enum Kind: String, Sendable, CaseIterable {
        case reply, setStatus, addTag, removeTag

        /// A change to a pull request's tags, rather than to one of its threads.
        public var isTags: Bool { self == .addTag || self == .removeTag }
    }

    public var kind: Kind {
        switch self {
        case .reply: .reply
        case .setStatus: .setStatus
        case .addTag: .addTag
        case .removeTag: .removeTag
        }
    }

    /// The pull request it changes, or one of whose threads it changes: every change is on one.
    public var pullRequest: PullRequestAddress {
        switch self {
        case .reply(let thread, _, _), .setStatus(let thread, _): thread.pullRequest
        case .addTag(let pullRequest, _), .removeTag(let pullRequest, _): pullRequest
        }
    }

    /// The thread it changes; nil for a change to the pull request itself.
    public var thread: ThreadAddress? {
        switch self {
        case .reply(let thread, _, _), .setStatus(let thread, _): thread
        case .addTag, .removeTag: nil
        }
    }

    /// POST for a reply, which adds a comment; PATCH for a status, which changes only that of the thread; POST for a tag added,
    /// and DELETE for one taken off.
    public var method: String {
        switch kind {
        case .reply: "POST"
        case .setStatus: "PATCH"
        case .addTag: "POST"
        case .removeTag: "DELETE"
        }
    }

    public var url: URL {
        let path = switch self {
        case .reply(let thread, _, _): pullRequest.path + ["threads", String(thread.id), "comments"]
        case .setStatus(let thread, _): pullRequest.path + ["threads", String(thread.id)]
        case .addTag: pullRequest.path + ["labels"]
        case .removeTag(_, let tag): pullRequest.path + ["labels", tag]
        }
        return ADOEndpoint.url("https://dev.azure.com", path, [("api-version", ADOEndpoint.apiVersion)])
    }

    /// Its JSON body, as Azure DevOps' own samples send them: a reply's text, the comment it replies to, and that it's text
    /// (`commentType` 1); only a status, by the number Azure DevOps takes for it, though it answers with its name; or a tag's
    /// name. Taking a tag off says nothing more than its address: it's empty, and sent as no body.
    public var body: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded: Data?
        switch self {
        case .reply(_, let markdown, let parent):
            encoded = try? encoder.encode(ReplyBody(content: markdown, parentCommentId: parent, commentType: 1))
        case .setStatus(_, let status):
            encoded = try? encoder.encode(StatusBody(status: status.number))
        case .addTag(_, let name):
            encoded = try? encoder.encode(TagBody(name: name))
        case .removeTag:
            encoded = Data()
        }
        // Strings and numbers always encode.
        return encoded ?? Data()
    }

    private struct ReplyBody: Encodable {
        var content: String
        var parentCommentId: Int
        var commentType: Int
    }

    private struct StatusBody: Encodable {
        var status: Int
    }

    private struct TagBody: Encodable {
        var name: String
    }

    /// What Azure DevOps answers a change with: the comment a reply added; the thread whose status changed, with its comments
    /// as it has them now; the tag added, as the project has it; that a tag was taken off, which it says nothing more of; or,
    /// when the change was made but its answer can't be read, why, for the pull request to be read again instead.
    public enum Answer: Sendable {
        case comment(ADOComment)
        case thread(ADOThread)
        case tag(ADOTag)
        case done
        case unreadable(String)
    }
}

/// A pull request, where Azure DevOps keeps it: in its organization's project and repository, by its number.
public struct PullRequestAddress: Sendable, Hashable {
    public var key: PRKey
    public var projectId: String
    public var repositoryId: String

    public init(key: PRKey, projectId: String, repositoryId: String) {
        self.key = key
        self.projectId = projectId
        self.repositoryId = repositoryId
    }

    public init(_ pullRequest: PullRequest) {
        self.init(key: pullRequest.key, projectId: pullRequest.projectId, repositoryId: pullRequest.repositoryId)
    }

    /// Its path on Azure DevOps' host, which a change to it, or to one of its threads, goes on from:
    /// `{organization}/{project}/_apis/git/repositories/{repository}/pullRequests/{number}`.
    var path: [String] {
        [key.organization, projectId, "_apis", "git", "repositories", repositoryId, "pullRequests", String(key.number)]
    }
}

/// One of a pull request's comment threads, where Azure DevOps keeps it.
public struct ThreadAddress: Sendable, Hashable {
    public var pullRequest: PullRequestAddress
    /// The thread's ID, which Azure DevOps numbers for each pull request.
    public var id: Int

    public init(_ pullRequest: PullRequestAddress, id: Int) {
        self.pullRequest = pullRequest
        self.id = id
    }

    public init(_ pullRequest: PullRequest, thread: Int) {
        self.init(PullRequestAddress(pullRequest), id: thread)
    }
}

/// A thread's status, as Azure DevOps names it (`CommentThreadStatus`): its API answers with these names.
public enum ThreadStatus: String, Sendable, CaseIterable, Codable {
    case active, pending, fixed, wontFix, closed, byDesign

    /// A thread's, as BriefBar read it; nil for one without a status, or with one it doesn't know, such as `unknown`.
    public init?(_ status: String?) {
        guard let status, let known = ThreadStatus(rawValue: status) else { return nil }
        self = known
    }

    /// The number Azure DevOps' API takes for it in a request, as its samples send it.
    var number: Int {
        switch self {
        case .active: 1
        case .fixed: 2
        case .wontFix: 3
        case .closed: 4
        case .byDesign: 5
        case .pending: 6
        }
    }

    /// As a menu says it, in the words of Azure DevOps' own: "Active", "Pending", "Resolved", "Won't Fix", "Closed",
    /// "By Design".
    public var title: String {
        switch self {
        case .active: "Active"
        case .pending: "Pending"
        case .fixed: "Resolved"
        case .wontFix: "Won't Fix"
        case .closed: "Closed"
        case .byDesign: "By Design"
        }
    }

    /// Fixed, won't fix, closed or by design: done with, one way or another (`ReviewThread.isResolved`).
    public var isResolved: Bool {
        switch self {
        case .fixed, .wontFix, .closed, .byDesign: true
        case .active, .pending: false
        }
    }

    /// What a thread's status menu offers, in Azure DevOps' order: By Design only for a thread that has it already, as
    /// Azure DevOps' own menu doesn't offer it anymore.
    public static func choices(for current: ThreadStatus?) -> [ThreadStatus] {
        let offered: [ThreadStatus] = [.active, .pending, .fixed, .wontFix, .closed]
        return current == .byDesign ? offered + [.byDesign] : offered
    }
}

extension ReviewThread {
    /// Its status, when it's one of those BriefBar knows (`ThreadStatus`).
    public var threadStatus: ThreadStatus? { ThreadStatus(status) }
}

/// A change BriefBar made to one of a pull request's threads, as Azure DevOps answered it, or, in the demo, as it's made up:
/// the comment it added; the thread's status; and, from an answer that has them, the thread's comments as Azure DevOps has
/// them now, such as a reply that came meanwhile.
public struct ThreadChange: Sendable, Equatable {
    public var thread: Int
    /// Its comments to add: one the thread has already, by its ID, stays as it is.
    public var comments: [ReviewComment]
    /// Its status now; nil when the answer didn't say.
    public var status: String?

    public init(thread: Int, comments: [ReviewComment] = [], status: String? = nil) {
        self.thread = thread
        self.comments = comments
        self.status = status
    }

    /// From Azure DevOps' answer to a change, its comments' mentions named as the pull request's other comments are; nil
    /// for one it can't read, or that isn't about the thread the change was.
    /// - Parameter known: the thread as BriefBar read it, whose comments' authors name mentions too.
    public init?(_ answer: ADOWrite.Answer, to write: ADOWrite, pullRequest: PullRequest, known: ReviewThread?) {
        var names = PRDetails.names(of: pullRequest)
        for comment in known?.comments ?? [] { names[comment.author.id] = comment.author.name }
        guard let address = write.thread else { return nil }
        switch answer {
        case .comment(let comment):
            guard let added = ReviewComment(comment, names: names, published: nil) else { return nil }
            self.init(thread: address.id, comments: [added])
        case .thread(let thread):
            guard thread.id == address.id else { return nil }
            let read = ReviewThread(thread, names: names)
            self.init(thread: thread.id, comments: read?.comments ?? [], status: thread.status)
        case .unreadable, .tag, .done:
            return nil
        }
    }
}

extension PRDetails {
    /// With a change BriefBar made to one of its threads, as Azure DevOps answered it: the comments it doesn't have, in the
    /// order they were made, and the thread's status. Nothing changes for a thread it doesn't have, which reading the pull
    /// request again brings, and the same change twice is the same as once.
    public mutating func apply(_ change: ThreadChange) {
        guard let index = threads.firstIndex(where: { $0.id == change.thread }) else { return }
        var thread = threads[index]
        let known = Set(thread.comments.map(\.id))
        let added = change.comments.filter { !known.contains($0.id) }
        if !added.isEmpty {
            thread.comments = (thread.comments + added).sorted { ($0.publishedAt, $0.id) < ($1.publishedAt, $1.id) }
            if let latest = added.map(\.publishedAt).max() { lastActivity = max(lastActivity ?? latest, latest) }
        }
        if let status = change.status { thread.status = status }
        threads[index] = thread
    }

    public func applying(_ change: ThreadChange) -> PRDetails {
        var details = self
        details.apply(change)
        return details
    }
}

/// Why a change BriefBar sent Azure DevOps didn't happen, or may not have, in a sentence for its thread, or by the tags.
public enum ADOWriteProblem: Sendable, Equatable {
    /// You may not reply there, or change the thread or the tags.
    case notAllowed
    /// Azure DevOps takes no change to the pull request anymore: it's completed or abandoned.
    case closed
    /// The thread, or its pull request, isn't there anymore; or the tag taken off isn't on the pull request.
    case gone
    case offline
    /// The Azure CLI isn't signed in, or Azure DevOps didn't take its sign-in.
    case signedOut
    /// Azure DevOps asked BriefBar to slow down.
    case slowedDown
    /// No answer came in time: it may have been made.
    case unanswered
    /// A reply that may have gone, as one Azure DevOps didn't answer in time, whose thread couldn't be read again to tell:
    /// it isn't sent again until it can be.
    case unconfirmed
    /// Azure DevOps refused it, with what it said, when it said something: never logged.
    case refused(String?)
    /// Someone else signed in to the Azure CLI since you asked for it: nothing went as them.
    case otherAccount
    /// The pull request isn't in your lists anymore, though its details still show it: nothing went.
    case notListed
    /// Anything else, as BriefBar says it.
    case failed(String)

    public init(_ error: Error) {
        guard let error = error as? ADOError else {
            self = .failed(error.localizedDescription)
            return
        }
        switch error {
        case .forbidden: self = .notAllowed
        case .notFound: self = .gone
        case .offline: self = .offline
        case .auth, .unauthorized, .otherDirectory: self = .signedOut
        case .throttled: self = .slowedDown
        case .network(ADOClient.unansweredMessage): self = .unanswered
        case .refused(let reason, let message): self = reason == .notEditable ? .closed : .refused(message)
        case .otherAccount: self = .otherAccount
        case .http, .network, .decoding, .redirected: self = .failed(error.description)
        }
    }

    /// Whether it may have been made after all, so that reading the thread again tells.
    public var mayHaveGone: Bool {
        self == .unanswered || self == .offline || self == .unconfirmed || { if case .failed = self { true } else { false } }()
    }

    /// What happened, in a sentence for the thread: "Azure DevOps says you may not reply here."
    public func sentence(_ kind: ADOWrite.Kind) -> String {
        if kind.isTags { return tagSentence(kind) }
        let change = kind == .reply ? "reply here" : "change this thread's status"
        switch self {
        case .notAllowed:
            return "Azure DevOps says you may not \(change)."
        case .closed:
            return "Azure DevOps takes no change to this pull request anymore: it's completed or abandoned."
        case .gone:
            return "Azure DevOps doesn't have this thread anymore: it, or its pull request, was deleted meanwhile."
        case .offline:
            return kind == .reply ? "You're offline. Your reply is kept: send it once you're back." : "You're offline: try again once you're back."
        case .signedOut:
            return "The Azure CLI isn't signed in, or Azure DevOps didn't take its sign-in: sign in, then try again."
        case .slowedDown:
            return "Azure DevOps asked BriefBar to slow down: try again in a minute."
        case .unanswered:
            return kind == .reply
                ? "Azure DevOps didn't answer in time, so your reply may have gone: BriefBar reads the thread again, and won't send it twice."
                : "Azure DevOps didn't answer in time: BriefBar reads the thread again, to show how it stands."
        case .unconfirmed:
            return kind == .reply
                ? "Your reply may have gone already, and BriefBar couldn't read the thread to check, so it didn't send it again: try again in a moment."
                : "BriefBar couldn't read the thread again: try again in a moment."
        case .refused(let said?):
            return "Azure DevOps refused it: \(said)"
        case .refused(nil):
            return "Azure DevOps refused it."
        case .otherAccount:
            return "Someone else is signed in to the Azure CLI now, so BriefBar sent nothing as them: sign in as yourself, then try again."
        case .notListed:
            return kind == .reply
                ? "This pull request is no longer in your lists, so your reply didn't go."
                : "This pull request is no longer in your lists, so this thread's status didn't change."
        case .failed(let why):
            return (kind == .reply ? "Couldn't reply: " : "Couldn't change its status: ") + why
        }
    }

    /// What happened to a change to a pull request's tags, in a sentence by them: "Azure DevOps says you may not change this
    /// pull request's tags."
    private func tagSentence(_ kind: ADOWrite.Kind) -> String {
        switch self {
        case .notAllowed:
            "Azure DevOps says you may not change this pull request's tags."
        case .closed:
            "Azure DevOps takes no change to this pull request anymore: it's completed or abandoned."
        case .gone:
            kind == .removeTag
                ? "Azure DevOps doesn't have that tag on this pull request, or doesn't have the pull request anymore."
                : "Azure DevOps doesn't have this pull request anymore: it was deleted meanwhile."
        case .offline:
            "You're offline: try again once you're back."
        case .signedOut:
            "The Azure CLI isn't signed in, or Azure DevOps didn't take its sign-in: sign in, then try again."
        case .slowedDown:
            "Azure DevOps asked BriefBar to slow down: try again in a minute."
        case .unanswered:
            "Azure DevOps didn't answer in time: BriefBar reads the tags again, to show how they stand."
        case .unconfirmed:
            "BriefBar couldn't read the tags again: try again in a moment."
        case .refused(let said?):
            "Azure DevOps refused it: \(said)"
        case .refused(nil):
            "Azure DevOps refused it."
        case .otherAccount:
            "Someone else is signed in to the Azure CLI now, so BriefBar sent nothing as them: sign in as yourself, then try again."
        case .failed(let why):
            (kind == .addTag ? "Couldn't add the tag: " : "Couldn't remove the tag: ") + why
        }
    }
}
