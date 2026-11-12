import Foundation

/// The only changes BriefBar makes in Azure DevOps, each when you click it, with **Make Changes in Azure DevOps** on: your
/// reply in a pull request's comment thread, a thread's status, a comment of yours edited or deleted, a tag you add to a
/// pull request or take off it, and, on My Work, a task or bug of yours moved to another sprint. Every other request
/// BriefBar sends Azure DevOps is a GET (`ADOClient.get`); these go only through `ADOClient.send(_:as:)`, which sends nothing
/// else, with the same sign-in, to the same host, following no redirect. Each is on a pull request (`pullRequest`), and a
/// thread's on one of its threads (`thread`), but a move, which is on a work item (`workItem`). A change BriefBar comes to
/// make later is another case here, and a kind of its own (`Kind`), which the tests go through.
public enum ADOWrite: Sendable, Equatable {
    /// Your comment in a thread, in reply to its first, in Markdown: `POST …/pullRequests/{id}/threads/{thread}/comments`.
    case reply(ThreadAddress, markdown: String, parentCommentId: Int)
    /// A thread's status, and nothing else of it: `PATCH …/pullRequests/{id}/threads/{thread}`.
    case setStatus(ThreadAddress, ThreadStatus)
    /// Your comment in a thread, saying what you wrote instead, in Markdown, and nothing else of it:
    /// `PATCH …/pullRequests/{id}/threads/{thread}/comments/{comment}`. Azure DevOps answers with the comment as it keeps it now.
    case editComment(ThreadAddress, comment: Int, markdown: String)
    /// Your comment in a thread, deleted: `DELETE …/pullRequests/{id}/threads/{thread}/comments/{comment}`. Azure DevOps keeps
    /// it, marked deleted (`isDeleted`), which it doesn't show, as BriefBar doesn't; and once none of the thread's comments is
    /// left, it deletes the thread too.
    case deleteComment(ThreadAddress, comment: Int)
    /// A tag on the pull request, by its name, which Azure DevOps calls a label: `POST …/pullRequests/{id}/labels`. It makes
    /// the project's tag too when the project has none of that name, and answers with the tag.
    case addTag(PullRequestAddress, name: String)
    /// A tag off the pull request, by the project's tag's ID, or else its name: `DELETE …/pullRequests/{id}/labels/{tag}`.
    /// The project keeps the tag.
    case removeTag(PullRequestAddress, tag: String)
    /// A work item moved to another iteration, such as your team's next sprint, and nothing else of it:
    /// `PATCH {organization}/_apis/wit/workitems/{id}`, a JSON Patch that sets `System.IterationPath` to `to`, but only while
    /// it's still `from`, as BriefBar last read it: when someone moved it meanwhile, Azure DevOps refuses it, rather than
    /// BriefBar moving it again over theirs. Azure DevOps answers with the work item as it keeps it now.
    case setIteration(WorkItemKey, from: String, to: String)

    /// Each change BriefBar can make, apart from what it says: tests go through all of them, so a new one comes with its
    /// own.
    public enum Kind: String, Sendable, CaseIterable {
        case reply, setStatus, editComment, deleteComment, addTag, removeTag, setIteration

        /// A change to a pull request's tags, rather than to one of its threads.
        public var isTags: Bool { self == .addTag || self == .removeTag }

        /// A change to one of your comments, rather than to its thread or the pull request's tags.
        public var isComment: Bool { self == .editComment || self == .deleteComment }

        /// A change to a work item, rather than to a pull request.
        public var isWorkItem: Bool { self == .setIteration }
    }

    public var kind: Kind {
        switch self {
        case .reply: .reply
        case .setStatus: .setStatus
        case .editComment: .editComment
        case .deleteComment: .deleteComment
        case .addTag: .addTag
        case .removeTag: .removeTag
        case .setIteration: .setIteration
        }
    }

    /// The pull request it changes, or one of whose threads it changes; nil for a change to a work item.
    public var pullRequest: PullRequestAddress? {
        switch self {
        case .reply(let thread, _, _), .setStatus(let thread, _), .editComment(let thread, _, _), .deleteComment(let thread, _):
            thread.pullRequest
        case .addTag(let pullRequest, _), .removeTag(let pullRequest, _): pullRequest
        case .setIteration: nil
        }
    }

    /// The thread it changes; nil for a change to the pull request itself, or to a work item.
    public var thread: ThreadAddress? {
        switch self {
        case .reply(let thread, _, _), .setStatus(let thread, _), .editComment(let thread, _, _), .deleteComment(let thread, _): thread
        case .addTag, .removeTag, .setIteration: nil
        }
    }

    /// The work item it changes; nil for a change to a pull request.
    public var workItem: WorkItemKey? {
        if case .setIteration(let key, _, _) = self { return key }
        return nil
    }

    /// POST for a reply, which adds a comment; PATCH for a status, which changes only that of the thread, and for a comment
    /// edited, only what it says; DELETE for a comment deleted; POST for a tag added, and DELETE for one taken off; PATCH
    /// for a work item moved, which changes only its iteration.
    public var method: String {
        switch kind {
        case .reply: "POST"
        case .setStatus: "PATCH"
        case .editComment: "PATCH"
        case .deleteComment: "DELETE"
        case .addTag: "POST"
        case .removeTag: "DELETE"
        case .setIteration: "PATCH"
        }
    }

    public var url: URL {
        let path: [String]
        switch self {
        case .reply(let thread, _, _): path = thread.pullRequest.path + ["threads", String(thread.id), "comments"]
        case .setStatus(let thread, _): path = thread.pullRequest.path + ["threads", String(thread.id)]
        case .editComment(let thread, let comment, _), .deleteComment(let thread, let comment):
            path = thread.pullRequest.path + ["threads", String(thread.id), "comments", String(comment)]
        case .addTag(let pullRequest, _): path = pullRequest.path + ["labels"]
        case .removeTag(let pullRequest, let tag): path = pullRequest.path + ["labels", tag]
        case .setIteration(let key, _, _): path = [key.organization, "_apis", "wit", "workitems", String(key.id)]
        }
        return ADOEndpoint.url("https://dev.azure.com", path, [("api-version", ADOEndpoint.apiVersion)])
    }

    /// What its body is: JSON, or, for a work item's change, a JSON Patch, which Azure DevOps takes only as that.
    public var contentType: String {
        kind.isWorkItem ? "application/json-patch+json" : "application/json"
    }

    /// Its JSON body, as Azure DevOps' own samples send them: a reply's text, the comment it replies to, and that it's text
    /// (`commentType` 1); only a status, by the number Azure DevOps takes for it, though it answers with its name; only what
    /// a comment edited says now; or a tag's name. Deleting a comment, or taking a tag off, says nothing more than its
    /// address: it's empty, and sent as no body. A move is a JSON Patch: a test that the work item is still in the iteration
    /// it was read in, then its new one.
    public var body: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded: Data?
        switch self {
        case .reply(_, let markdown, let parent):
            encoded = try? encoder.encode(ReplyBody(content: markdown, parentCommentId: parent, commentType: 1))
        case .setStatus(_, let status):
            encoded = try? encoder.encode(StatusBody(status: status.number))
        case .editComment(_, _, let markdown):
            encoded = try? encoder.encode(EditBody(content: markdown))
        case .deleteComment:
            encoded = Data()
        case .addTag(_, let name):
            encoded = try? encoder.encode(TagBody(name: name))
        case .removeTag:
            encoded = Data()
        case .setIteration(_, let from, let to):
            encoded = try? encoder.encode([
                PatchOperation(op: "test", path: Self.iterationField, value: from),
                PatchOperation(op: "add", path: Self.iterationField, value: to),
            ])
        }
        // Strings and numbers always encode.
        return encoded ?? Data()
    }

    /// Where a work item's iteration is, in a JSON Patch.
    static let iterationField = "/fields/System.IterationPath"

    private struct PatchOperation: Encodable {
        var op: String
        var path: String
        var value: String
    }

    private struct ReplyBody: Encodable {
        var content: String
        var parentCommentId: Int
        var commentType: Int
    }

    private struct StatusBody: Encodable {
        var status: Int
    }

    private struct EditBody: Encodable {
        var content: String
    }

    private struct TagBody: Encodable {
        var name: String
    }

    /// What Azure DevOps answers a change with: the comment a reply added, or that you edited, as it keeps it now; the thread
    /// whose status changed, with its comments as it has them now; the tag added, as the project has it; the work item moved,
    /// as it keeps it now; that a comment was deleted, or a tag taken off, which it says nothing more of; or, when the change
    /// was made but its answer can't be read, why, for what it changed to be read again instead.
    public enum Answer: Sendable {
        case comment(ADOComment)
        case thread(ADOThread)
        case tag(ADOTag)
        case workItem(ADOWorkItem)
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
/// them now, such as a reply that came meanwhile; a comment of yours as you edited it; or one you deleted.
public struct ThreadChange: Sendable, Equatable {
    public var thread: Int
    /// Its comments to add: one the thread has already, by its ID, stays as it is.
    public var comments: [ReviewComment]
    /// Its status now; nil when the answer didn't say.
    public var status: String?
    /// Comments of yours as you edited them, as Azure DevOps keeps them now: each in place of the one with its ID, while that
    /// says something else.
    public var edited: [ReviewComment]
    /// Comments of yours you deleted, by their IDs: they leave the thread, and the thread leaves too once none of its comments
    /// is left, as Azure DevOps deletes it then.
    public var deleted: [Int]

    public init(thread: Int, comments: [ReviewComment] = [], status: String? = nil, edited: [ReviewComment] = [], deleted: [Int] = []) {
        self.thread = thread
        self.comments = comments
        self.status = status
        self.edited = edited
        self.deleted = deleted
    }

    /// It changes nothing.
    public var isEmpty: Bool { comments.isEmpty && status == nil && edited.isEmpty && deleted.isEmpty }

    /// From Azure DevOps' answer to a change, its comments' mentions named as the pull request's other comments are; nil
    /// for one it can't read, or that isn't about the thread, or the comment, the change was.
    /// - Parameters:
    ///   - known: the thread as BriefBar read it, whose comments' authors, and the names its comments' mentions showed as,
    ///     name mentions too.
    ///   - date: when it answered: when a comment you edited was, if the answer doesn't say.
    public init?(_ answer: ADOWrite.Answer, to write: ADOWrite, pullRequest: PullRequest, known: ReviewThread?, at date: Date = Date()) {
        var names = PRDetails.names(of: pullRequest)
        for comment in known?.comments ?? [] {
            names[comment.author.id] = comment.author.name
            names.merge(comment.mentionNames) { named, _ in named }
        }
        guard let address = write.thread else { return nil }
        switch (answer, write) {
        case (.comment(let comment), .editComment(_, let id, _)):
            let before = known?.comments.first { $0.id == id }
            guard comment.id == id, var edited = ReviewComment(comment, names: names, published: before?.publishedAt) else { return nil }
            // Edited, as you just did, though Azure DevOps doesn't say when what it says changed: when it last changed anything
            // of it, by its own clock, as the dates edits are compared by (`PRDetails.apply`), or else as it answered.
            if edited.editedAt == nil {
                let published = edited.publishedAt
                edited.editedAt = comment.lastUpdatedDate.flatMap { $0.timeIntervalSince(published) > 1 ? $0 : nil } ?? max(date, published)
            }
            self.init(thread: address.id, edited: [edited])
        case (.comment(let comment), _):
            guard let added = ReviewComment(comment, names: names, published: nil) else { return nil }
            self.init(thread: address.id, comments: [added])
        case (.thread(let thread), _):
            guard thread.id == address.id else { return nil }
            let read = ReviewThread(thread, names: names)
            self.init(thread: thread.id, comments: read?.comments ?? [], status: thread.status)
        case (.done, .deleteComment(_, let id)):
            self.init(thread: address.id, deleted: [id])
        case (.unreadable, _), (.tag, _), (.workItem, _), (.done, _):
            return nil
        }
    }
}

extension PRDetails {
    /// With a change BriefBar made to one of its threads, as Azure DevOps answered it: the comments it doesn't have, in the
    /// order they were made; a comment of yours as you edited it, in place of one that says something else, unless that one
    /// was edited later, as elsewhere, which a read had before this edit's answer came, as Azure DevOps dates each edit;
    /// without one you deleted, and without the thread once none of its comments is left, as Azure DevOps deletes it then;
    /// and the thread's status. Nothing changes for a thread it doesn't have, which reading the pull request again brings,
    /// nor for a comment it doesn't have, and the same change twice is the same as once.
    public mutating func apply(_ change: ThreadChange) {
        guard let index = threads.firstIndex(where: { $0.id == change.thread }) else { return }
        var thread = threads[index]
        let known = Set(thread.comments.map(\.id))
        let added = change.comments.filter { !known.contains($0.id) }
        if !added.isEmpty {
            thread.comments = (thread.comments + added).sorted { ($0.publishedAt, $0.id) < ($1.publishedAt, $1.id) }
            if let latest = added.map(\.publishedAt).max() { lastActivity = max(lastActivity ?? latest, latest) }
        }
        for edited in change.edited {
            guard let index = thread.comments.firstIndex(where: { $0.id == edited.id }) else { continue }
            let known = thread.comments[index]
            guard known.kept != edited.kept else { continue }
            if let later = known.editedAt, let at = edited.editedAt, later > at { continue }
            thread.comments[index] = edited
        }
        if !change.deleted.isEmpty { thread.comments.removeAll { change.deleted.contains($0.id) } }
        if let status = change.status { thread.status = status }
        if thread.comments.isEmpty {
            threads.remove(at: index)
        } else {
            threads[index] = thread
        }
    }

    public func applying(_ change: ThreadChange) -> PRDetails {
        var details = self
        details.apply(change)
        return details
    }
}

/// Why a change BriefBar sent Azure DevOps didn't happen, or may not have, in a sentence for its thread, by the tags, or, for
/// a work item moved, on My Work.
public enum ADOWriteProblem: Sendable, Equatable {
    /// You may not reply there, or change the thread, the comment, the tags or the work item.
    case notAllowed
    /// Azure DevOps takes no change to the pull request anymore: it's completed or abandoned.
    case closed
    /// The thread, the comment, or its pull request, isn't there anymore; or the tag taken off isn't on the pull request; or
    /// the work item isn't there anymore, or you can't see it.
    case gone
    case offline
    /// The Azure CLI isn't signed in, or Azure DevOps didn't take its sign-in.
    case signedOut
    /// Azure DevOps asked BriefBar to slow down, until then, for what it reads too: nothing goes before.
    case slowedDown(until: Date)
    /// No answer came in time: it may have been made.
    case unanswered
    /// A reply, an edit or a deletion that may have gone, as one Azure DevOps didn't answer in time, whose thread couldn't be
    /// read again to tell: it isn't sent again until it can be.
    case unconfirmed
    /// Azure DevOps refused it, with what it said, when it said something: never logged.
    case refused(String?)
    /// Someone else signed in to the Azure CLI since you asked for it: nothing went as them.
    case otherAccount
    /// The pull request isn't in your lists anymore, though its details still show it; or the work item isn't among yours
    /// that BriefBar reads anymore: nothing went.
    case notListed
    /// Anything else, as BriefBar says it.
    case failed(String)

    /// - Parameter now: when it happened, from which a wait Azure DevOps asked for runs.
    public init(_ error: Error, now: Date = Date()) {
        guard let error = error as? ADOError else {
            self = .failed(error.localizedDescription)
            return
        }
        switch error {
        case .forbidden: self = .notAllowed
        case .notFound: self = .gone
        case .offline: self = .offline
        case .auth, .unauthorized, .otherDirectory: self = .signedOut
        case .throttled(let wait): self = .slowedDown(until: now.addingTimeInterval(wait))
        case .network(ADOClient.unansweredMessage): self = .unanswered
        case .refused(let reason, let message): self = reason == .notEditable ? .closed : .refused(message)
        case .otherAccount: self = .otherAccount
        case .http, .network, .decoding, .redirected: self = .failed(error.description)
        }
    }

    /// A time to try again at, as a sentence says it, "3:06 PM": the minute it ends in, so that it's never too soon.
    static func time(_ date: Date) -> String {
        let minute = (date.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60
        return Date(timeIntervalSinceReferenceDate: minute).formatted(date: .omitted, time: .shortened)
    }

    /// Whether it may have been made after all, so that reading the thread again tells.
    public var mayHaveGone: Bool {
        self == .unanswered || self == .offline || self == .unconfirmed || { if case .failed = self { true } else { false } }()
    }

    /// What happened, in a sentence for the thread: "Azure DevOps says you may not reply here."
    public func sentence(_ kind: ADOWrite.Kind) -> String {
        if kind.isWorkItem { return moveSentence() }
        if kind.isTags { return tagSentence(kind) }
        if kind.isComment { return commentSentence(kind) }
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
        case .slowedDown(let until):
            return "Azure DevOps asked BriefBar to slow down, until \(Self.time(until)): try again then."
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

    /// What happened to a comment of yours you edited or deleted, in a sentence for its thread, or in your edit: "Azure DevOps
    /// says you may not edit this comment."
    private func commentSentence(_ kind: ADOWrite.Kind) -> String {
        let isEdit = kind == .editComment
        switch self {
        case .notAllowed:
            return isEdit ? "Azure DevOps says you may not edit this comment." : "Azure DevOps says you may not delete this comment."
        case .closed:
            return "Azure DevOps takes no change to this pull request anymore: it's completed or abandoned."
        case .gone:
            return "Azure DevOps doesn't have this comment anymore: it, its thread or its pull request was deleted meanwhile."
        case .offline:
            return isEdit ? "You're offline. Your edit is kept: save it once you're back." : "You're offline: try again once you're back."
        case .signedOut:
            return "The Azure CLI isn't signed in, or Azure DevOps didn't take its sign-in: sign in, then try again."
        case .slowedDown(let until):
            return "Azure DevOps asked BriefBar to slow down, until \(Self.time(until)): try again then."
        case .unanswered:
            return isEdit
                ? "Azure DevOps didn't answer in time, so your edit may have been saved: BriefBar reads the thread again, and won't save it twice."
                : "Azure DevOps didn't answer in time, so your comment may have been deleted: BriefBar reads the thread again, to show how it stands."
        case .unconfirmed:
            return isEdit
                ? "Your edit may have been saved already, and BriefBar couldn't read the thread to check, so it didn't save it again: try again in a moment."
                : "Your comment may have been deleted already, and BriefBar couldn't read the thread to check, so it didn't delete it again: try again in a moment."
        case .refused(let said?):
            return "Azure DevOps refused it: \(said)"
        case .refused(nil):
            return "Azure DevOps refused it."
        case .otherAccount:
            return "Someone else is signed in to the Azure CLI now, so BriefBar sent nothing as them: sign in as yourself, then try again."
        case .notListed:
            return isEdit
                ? "This pull request is no longer in your lists, so your edit wasn't saved."
                : "This pull request is no longer in your lists, so your comment wasn't deleted."
        case .failed(let why):
            return (isEdit ? "Couldn't save your edit: " : "Couldn't delete your comment: ") + why
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
        case .slowedDown(let until):
            "Azure DevOps asked BriefBar to slow down, until \(Self.time(until)): try again then."
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
        case .notListed:
            "This pull request is no longer in your lists, so its tags didn't change."
        case .failed(let why):
            (kind == .addTag ? "Couldn't add the tag: " : "Couldn't remove the tag: ") + why
        }
    }

    /// What happened to a work item you moved to another sprint, in a sentence for My Work: "Azure DevOps says you may not
    /// change this work item." Refused, as when someone moved it meanwhile, it says what Azure DevOps said.
    private func moveSentence() -> String {
        switch self {
        case .notAllowed:
            "Azure DevOps says you may not change this work item."
        case .closed:
            "Azure DevOps takes no change to this work item anymore."
        case .gone:
            "Azure DevOps doesn't have this work item anymore, or you can't see it now."
        case .offline:
            "You're offline: try again once you're back."
        case .signedOut:
            "The Azure CLI isn't signed in, or Azure DevOps didn't take its sign-in: sign in, then try again."
        case .slowedDown(let until):
            "Azure DevOps asked BriefBar to slow down, until \(Self.time(until)): try again then."
        case .unanswered:
            "Azure DevOps didn't answer in time, so it may have moved: BriefBar reads your work again, to show where it is."
        case .unconfirmed:
            "BriefBar couldn't read your work again to tell where it is: try again in a moment."
        case .refused(let said?):
            "Azure DevOps refused it: \(said)"
        case .refused(nil):
            "Azure DevOps refused it."
        case .otherAccount:
            "Someone else is signed in to the Azure CLI now, so BriefBar sent nothing as them: sign in as yourself, then try again."
        case .notListed:
            "As BriefBar reads your work now, it isn't where it was when you chose to move it, so it didn't move."
        case .failed(let why):
            "Couldn't move it: " + why
        }
    }
}
