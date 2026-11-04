import BriefBarCore
import Foundation

/// What a pull request's details show of it, beside the list in BriefBar's window: where it stands, what's left before it
/// can complete, its comment threads, its builds and checks, and who reviews it. All of it is what BriefBar read already for
/// the lists (`PRSnapshot`, `PRRecord`): nothing more is read for it.
public struct PullRequestPanel: Sendable, Equatable {
    /// A part of the details that what's left can lead to: its threads, its merge conflicts, its builds and checks, or its
    /// reviewers.
    public enum Section: String, Sendable, Hashable, CaseIterable {
        case comments, conflicts, checks, reviewers
    }

    /// The branch it merges, and into which: "payments-retry → main"; nil when that isn't known.
    public var branch: String?
    /// Who wrote it.
    public var author: String
    /// You wrote it.
    public var isYours: Bool
    /// Where it stands, as its row says it: "Sam Rivera replied: Could we cap the backoff at 30 seconds?".
    public var sentence: String
    /// Since when it stands so.
    public var since: Date?
    /// How the merge of an open pull request stands, when there's something to say: "Conflicts with main · Completes by
    /// itself once it can".
    public var merge: String?
    /// What's left before you can complete it, and what's done: for your own open pull requests, once their details are
    /// read.
    public var readiness: PRReadiness?
    /// Whether its threads and policies were read: an open pull request's are, after the list first reads it.
    public var hasDetails: Bool
    /// It's completed or abandoned: the list reads a pull request's threads and policies only while it's open.
    public var isClosed: Bool
    /// It's open, and its merge with its target branch conflicts, as Azure DevOps says it: its details list the files that
    /// conflict.
    public var hasConflicts: Bool
    public var threads: Threads
    /// Its builds and status checks, and the pipelines that ran after it merged, what failed first.
    public var checks: [CheckLine]
    /// False when its project doesn't let you read its policies: then nobody can tell its builds and checks.
    public var checksKnown: Bool
    /// Its details say nobody can tell its builds and checks: they can't, and there's nothing else to show, such as the
    /// pipelines that ran after it merged.
    public var checksUnknown: Bool { !checksKnown && checks.isEmpty }
    /// Who reviews it, the ones it requires first.
    public var reviewers: [ReviewerLine]

    /// - Parameter events: what needs you on it, when the details tell it otherwise than its row does now: as it was when
    /// they showed it (`PullRequestDetailsStore.pendingEvents`).
    public init(_ snapshot: PRSnapshot, record: PRRecord?, events: [PREvent]? = nil) {
        let pullRequest = record?.pullRequest
        let details = record?.details
        branch = pullRequest.flatMap(PullRequestStory.branch)
        author = snapshot.author
        isYours = snapshot.role == .author
        sentence = PullRequestStory.sentence(of: snapshot)
        since = snapshot.since
        merge = pullRequest.flatMap(PullRequestStory.merge)
        readiness = snapshot.readiness
        hasDetails = details != nil
        isClosed = pullRequest.map { $0.status == .completed || $0.status == .abandoned }
            ?? (snapshot.group == .done || snapshot.merge != nil)
        hasConflicts = pullRequest.map { $0.status == .active && $0.hasConflicts } ?? false
        threads = Threads(details?.threads ?? [], events: events ?? snapshot.pendingEvents)
        var checks = (details?.checks ?? []).compactMap { check in
            PullRequestStory.run(check, organization: snapshot.key.organization, project: snapshot.project).map {
                CheckLine(run: $0, check: check)
            }
        }
        if let merge = snapshot.merge { checks.append(CheckLine(afterMerge: merge)) }
        self.checks = CheckLine.identified(checks.sorted(by: CheckLine.showsFirst))
        checksKnown = details?.checksKnown ?? true
        reviewers = (pullRequest?.reviewers ?? []).map { ReviewerLine($0, me: record?.me) }.sorted(by: ReviewerLine.showsFirst)
    }

    /// Where an item of what's left leads: comments to the threads, conflicts to the files that conflict, builds and checks
    /// to them, approvals and reviewers to who reviews it; nil for what has no part of its own, such as a draft or a linked
    /// work item.
    public static func section(of item: PRReadiness.Item) -> Section? {
        switch item.kind {
        case .comments: .comments
        case .conflicts: .conflicts
        case .builds, .checks: .checks
        case .approvals, .requiredReviewers, .changesRequested: .reviewers
        case .draft, .workItems, .policy, .mergeFailed, .unreadablePolicies: nil
        }
    }
}

// MARK: - Threads

extension PullRequestPanel {
    /// A comment thread, on a line of code or on the whole pull request.
    public struct Thread: Sendable, Equatable, Identifiable {
        public var thread: ReviewThread
        /// A comment in it needs you, as the list says: a reply, a mention or a comment you haven't answered.
        public var waitsOnYou: Bool
        /// What needs you in it is new: it came after you last looked.
        public var isNew: Bool

        public var id: Int { thread.id }
        public var comments: [ReviewComment] { thread.comments }
        public var isResolved: Bool { thread.isResolved }
        /// When something was last said in it.
        public var date: Date? { thread.comments.map(\.publishedAt).max() }

        /// Where it is: "PaymentsClient.cs:88", "PaymentsClient.cs" for a whole file; nil for one on the whole pull request.
        public var place: String? {
            guard let name = thread.fileName, !name.isEmpty else { return nil }
            return thread.line.map { "\(name):\($0)" } ?? name
        }

        /// Its status, as Azure DevOps names it: "Active", "Pending", "Resolved", "Won't fix", "Closed", "By design"; nil
        /// when it has none.
        public var status: String? {
            switch thread.status {
            case "active"?: "Active"
            case "pending"?: "Pending"
            case "fixed"?: "Resolved"
            case "wontFix"?: "Won't fix"
            case "closed"?: "Closed"
            case "byDesign"?: "By design"
            default: nil
            }
        }
    }

    /// The threads, as the details list them: those that wait on you first, then the other open ones, then the resolved
    /// ones, folded until you ask; the latest first in each.
    public struct Threads: Sendable, Equatable {
        /// With a comment that waits on you, resolved or not.
        public var waitingOnYou: [Thread]
        /// Open, but waiting on someone else, or on no one.
        public var open: [Thread]
        /// Fixed, won't fix, closed or by design.
        public var resolved: [Thread]

        public init(waitingOnYou: [Thread] = [], open: [Thread] = [], resolved: [Thread] = []) {
            self.waitingOnYou = waitingOnYou
            self.open = open
            self.resolved = resolved
        }

        /// - Parameter events: what needs you on the pull request, as its row has it: those of its threads wait on you.
        init(_ threads: [ReviewThread], events: [PREvent]) {
            var waiting: [Int: Bool] = [:]
            for event in events {
                guard let thread = event.threadId else { continue }
                waiting[thread] = (waiting[thread] ?? false) || event.isNew
            }
            let all = threads
                .map { Thread(thread: $0, waitsOnYou: waiting[$0.id] != nil, isNew: waiting[$0.id] == true) }
                .sorted { lhs, rhs in
                    if lhs.date != rhs.date { return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast) }
                    return lhs.id > rhs.id
                }
            self.init(
                waitingOnYou: all.filter(\.waitsOnYou),
                open: all.filter { !$0.waitsOnYou && !$0.isResolved },
                resolved: all.filter { !$0.waitsOnYou && $0.isResolved }
            )
        }

        /// The ones that aren't resolved, or that wait on you.
        public var unresolvedCount: Int { waitingOnYou.count + open.count }
        public var isEmpty: Bool { waitingOnYou.isEmpty && open.isEmpty && resolved.isEmpty }
        public var all: [Thread] { waitingOnYou + open + resolved }

        public func contains(_ id: Int) -> Bool {
            all.contains { $0.id == id }
        }
    }
}

// MARK: - Checks

extension PullRequestPanel {
    /// A build or a status check that validates the pull request, or the pipelines that ran after it merged.
    public struct CheckLine: Sendable, Equatable, Identifiable {
        /// As a pull request's page shows its pipelines (`PullRequestStory.run`): its name, where it stands, the first
        /// error where it failed, and its run's page.
        public var run: ItemStory.Run
        /// The policy it comes from; nil for the pipelines that ran after it merged.
        public var check: Check?
        /// Whether it holds the pull request up until it passes: an optional one doesn't.
        public var isRequired: Bool
        /// The run: the build a policy queued, or the run after its merge that failed, waits or was canceled.
        public var buildId: Int?
        /// Its run, or else its name, and which of those of that name it is, for two policies of the same name.
        public private(set) var id: String

        init(run: ItemStory.Run, check: Check) {
            self.run = run
            self.check = check
            isRequired = check.isBlocking
            buildId = check.buildId
            id = check.buildId.map { "run \($0)" } ?? "check \(run.name)"
        }

        init(afterMerge merge: MergeSummary) {
            run = PullRequestStory.run(merge)
            check = nil
            isRequired = false
            buildId = merge.runId
            id = merge.runId.map { "run \($0)" } ?? "after merge \(run.name)"
        }

        /// Each with an ID of its own: the second of the same name or run is "check Build 2", or the first number after
        /// that no other has, as when another is named "Build 2".
        static func identified(_ lines: [CheckLine]) -> [CheckLine] {
            var used: Set<String> = []
            return lines.map { line in
                var line = line
                let base = line.id
                var number = 1
                while !used.insert(line.id).inserted {
                    number += 1
                    line.id = "\(base) \(number)"
                }
                return line
            }
        }

        /// What failed first, then what needs you, what's running, what waits, and what passed; the required one first,
        /// then the latest.
        static func showsFirst(_ lhs: CheckLine, _ rhs: CheckLine) -> Bool {
            func rank(_ line: CheckLine) -> Int {
                switch line.run.state {
                case .failing?: 0
                case .needsYou?: 1
                case .running?: 2
                case nil: 3
                case .done?: 4
                }
            }
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            if lhs.isRequired != rhs.isRequired { return lhs.isRequired }
            return ItemStory.Run.showsFirst(lhs.run, rhs.run)
        }
    }
}

// MARK: - Reviewers

extension PullRequestPanel {
    /// Someone who reviews it, or a team: how they voted, and whether it requires them.
    public struct ReviewerLine: Sendable, Equatable, Identifiable {
        public var id: String
        /// A person's name; a team's without its project: "Storefront Team".
        public var name: String
        public var vote: Vote
        public var isRequired: Bool
        public var isGroup: Bool
        public var hasDeclined: Bool
        public var isYou: Bool

        init(_ reviewer: Reviewer, me: String?) {
            id = reviewer.person.id
            name = reviewer.isGroup ? PRReadiness.shortName(reviewer) : reviewer.person.name
            vote = reviewer.vote
            isRequired = reviewer.isRequired
            isGroup = reviewer.isGroup
            hasDeclined = reviewer.hasDeclined
            isYou = PullRequestStory.isMe(reviewer.person, me)
        }

        /// How they voted, in a word or a few: "Approved", "Approved with suggestions", "Wants changes", "Rejected",
        /// "Declined", "No vote yet".
        public var verdict: String {
            if hasDeclined { return "Declined" }
            switch vote {
            case .approved: return "Approved"
            case .approvedWithSuggestions: return "Approved with suggestions"
            case .waitingForAuthor: return "Wants changes"
            case .rejected: return "Rejected"
            case .none: return "No vote yet"
            }
        }

        /// The ones it requires first, people before teams, then by name.
        static func showsFirst(_ lhs: ReviewerLine, _ rhs: ReviewerLine) -> Bool {
            if lhs.isRequired != rhs.isRequired { return lhs.isRequired }
            if lhs.isGroup != rhs.isGroup { return !lhs.isGroup }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
