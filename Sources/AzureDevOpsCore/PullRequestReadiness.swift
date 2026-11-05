import BriefBarCore
import Foundation

/// What's left before you can complete one of your pull requests, and what's done: each thing Azure DevOps requires of it,
/// from its blocking policies, its reviewers' votes and its merge, as BriefBar last read them. Its row says the one thing
/// that matters most; this says all of them at once, so you can tell which are ready and what holds up the rest.
public struct PRReadiness: Sendable, Codable, Equatable {
    /// One requirement, met or not.
    public struct Item: Sendable, Codable, Equatable, Hashable {
        public enum Kind: String, Sendable, Codable {
            /// It's a draft, which can't be completed.
            case draft
            /// A reviewer wants changes, or rejected it.
            case changesRequested
            /// Enough approvals, as its minimum-reviewers policy wants; or, without reviewer policies, one.
            case approvals
            /// The reviewers it requires, whether a policy or someone added them.
            case requiredReviewers
            /// Its build validation pipelines.
            case builds
            /// The statuses other services post on it.
            case checks
            /// Its comment threads: resolved, as a policy wants, or still open.
            case comments
            /// A linked work item, as a policy wants.
            case workItems
            /// Any other blocking policy, by its name.
            case policy
            /// Merge conflicts with its target branch.
            case conflicts
            /// A merge Azure DevOps couldn't make otherwise: it failed, or a policy rejected it.
            case mergeFailed
            /// Its project doesn't let you read its policies, so nobody can tell whether it's ready.
            case unreadablePolicies
        }

        public var kind: Kind
        /// Done; failing; waiting on you, such as comments to resolve; running; or nil while it waits on someone else,
        /// such as a reviewer.
        public var state: ItemState?
        /// In a few words: "1 of 2 approvals", "Build failed", "Resolve 2 comments".
        public var label: String
        /// More about it, for its tooltip: "Approved by Priya Shah", "shop-web CI · Run unit tests: 2 tests failed".
        public var detail: String?
        /// Whether it holds the pull request up until it's done: open comments that no policy requires resolving don't.
        public var isRequired: Bool

        public init(kind: Kind, state: ItemState?, label: String, detail: String? = nil, isRequired: Bool = true) {
            self.kind = kind
            self.state = state
            self.label = label
            self.detail = detail
            self.isRequired = isRequired
        }

        public var isDone: Bool { state == .done }
    }

    /// What's left first, as the lists order states: what waits on you, what failed, what's running, what waits on someone
    /// else, and what doesn't hold it up; then what's done. Each in the order Azure DevOps lists them.
    public var items: [Item]
    /// Its policies were read as it is now: false once it changed, by a push or a vote, until they're read again.
    public var isCurrent: Bool

    public init(items: [Item], isCurrent: Bool = true) {
        self.items = items
        self.isCurrent = isCurrent
    }

    /// Whether you can complete it as it is now: what was read of it is current, and everything it requires is done.
    public var isReady: Bool {
        isCurrent && !items.contains { $0.isRequired && !$0.isDone }
    }

    /// What's left: everything that isn't done.
    public var left: [Item] { items.filter { !$0.isDone } }
}

extension PRReadiness {
    static let minimumReviewers = "Minimum number of reviewers"
    static let requiredReviewers = "Required reviewers"
    static let commentRequirements = "Comment requirements"
    static let workItemLinking = "Work item linking"

    /// For one of your open pull requests, once its details have been read; nil for any other.
    public init?(_ record: PRRecord) {
        let pr = record.pullRequest
        guard record.role == .author, pr.status == .active, let details = record.details else { return nil }
        self.init(pr, details)
    }

    /// As `PRClassifier` decides it's ready to complete: the same policies, read the same way, and the same votes.
    init(_ pr: PullRequest, _ details: PRDetails) {
        let blocking = details.checks.filter { $0.isBlocking && $0.kind != .completion && $0.state != .notApplicable }
        var items: [Item] = []
        func add(_ kind: Item.Kind, _ state: ItemState?, _ label: String, _ detail: String? = nil, required: Bool = true) {
            items.append(Item(kind: kind, state: state, label: label, detail: detail, isRequired: required))
        }

        if pr.isDraft {
            add(.draft, .needsYou, "Publish the draft", "A draft can't be completed")
        }

        // Reviewers. Groups, such as a team a policy adds, count only as their policies say.
        let people = pr.reviewers.filter { !$0.isGroup }
        let approvals = people.filter(\.vote.isApproval)
        let approvedBy = approvals.isEmpty ? nil : "Approved by " + PullRequestStory.names(approvals.map(\.person.name))
        let wantChanges = people.filter(\.vote.wantsChanges)
        if let first = wantChanges.first(where: { $0.vote == .rejected }) ?? wantChanges.first {
            let label = wantChanges.count > 1 ? "Changes requested"
                : first.vote == .rejected ? "\(first.person.firstName) rejected it" : "\(first.person.firstName) wants changes"
            let rejected = wantChanges.filter { $0.vote == .rejected }.map(\.person.name)
            let waiting = wantChanges.filter { $0.vote == .waitingForAuthor }.map(\.person.name)
            let detail = [
                rejected.isEmpty ? nil : "Rejected by " + PullRequestStory.names(rejected),
                waiting.isEmpty ? nil : "Changes requested by " + PullRequestStory.names(waiting),
            ].compactMap { $0 }.joined(separator: " · ")
            add(.changesRequested, .needsYou, label, detail)
        }

        let reviewerPolicies = blocking.filter { $0.kind == .reviewers }
        let minimumPolicies = reviewerPolicies.filter { $0.name == Self.minimumReviewers }
        // As the classifier has it: a reviewer policy that doesn't apply still means approvals are up to the policies.
        let hasReviewerPolicy = details.checks.contains { $0.kind == .reviewers && $0.isBlocking }
        if !minimumPolicies.isEmpty {
            // How many the one that isn't met yet wants, as the list's detail says it.
            let pending = minimumPolicies.filter { $0.state != .passed }
            let minimum = pending.compactMap(\.minimumApprovers).max() ?? 1
            let label = if pending.isEmpty {
                "Approved"
            } else if approvals.count >= minimum {
                // Enough people approved, but not as the policy counts them: say, the last one to push can't approve.
                "Approval policy pending"
            } else {
                minimum > 1 ? "\(approvals.count) of \(minimum) approvals" : "Not approved yet"
            }
            add(.approvals, pending.isEmpty ? .done : nil, label, approvedBy)
        } else if !hasReviewerPolicy || !approvals.isEmpty {
            // Without a reviewer policy, BriefBar wants someone's approval before it says it's ready.
            add(.approvals, approvals.isEmpty ? nil : .done, approvals.isEmpty ? "Not approved yet" : "Approved", approvedBy)
        }

        // A reviewer it requires holds it up until they approve, whether a policy or someone added them, even one who
        // declined. Who wants changes is said already. A team is waited on only as a pending policy requires it: one whose
        // own policy passed isn't, whatever its vote; every one that hasn't approved, when a pending policy doesn't say.
        let requiredPolicies = reviewerPolicies.filter { $0.name == Self.requiredReviewers }
        let pendingPolicies = requiredPolicies.filter { $0.state != .passed }
        let requiredPeople = people.filter { $0.isRequired && !$0.vote.isApproval && !$0.vote.wantsChanges }
        let pendingIds = Set(pendingPolicies.flatMap(\.reviewerIds))
        let unsaid = pendingPolicies.contains { $0.reviewerIds.isEmpty }
        let requiredGroups = pr.reviewers.filter { reviewer in
            reviewer.isGroup && reviewer.isRequired && !reviewer.vote.isApproval && (unsaid || pendingIds.contains(reviewer.person.id))
        }
        let waitingOn = requiredPeople + requiredGroups
        if !waitingOn.isEmpty || !pendingPolicies.isEmpty {
            let label = switch waitingOn.count {
            case 0: "Required reviewers"
            case 1: "Waiting on \(Self.shortName(waitingOn[0]))"
            default: "Waiting on \(waitingOn.count) reviewers"
            }
            let detail = waitingOn.isEmpty ? nil : "Required: " + PullRequestStory.names(waitingOn.map(\.person.name), limit: 5)
            add(.requiredReviewers, nil, label, detail)
        } else if !requiredPolicies.isEmpty {
            add(.requiredReviewers, .done, "Required reviewers")
        }

        for (name, checks) in Self.byName(reviewerPolicies.filter { $0.name != Self.minimumReviewers && $0.name != Self.requiredReviewers }) {
            add(.policy, checks.allSatisfy { $0.state == .passed } ? .done : nil, name)
        }

        let builds = blocking.filter { $0.kind == .build }
        if !builds.isEmpty { items.append(Self.builds(builds)) }
        let statuses = blocking.filter { $0.kind == .status }
        if !statuses.isEmpty { items.append(Self.checks(statuses)) }

        let requirements = blocking.filter { $0.kind == .requirement }
        let open = details.threads.filter { $0.status == "active" || $0.status == "pending" }.count
        let commentPolicies = requirements.filter { $0.name == Self.commentRequirements }
        if !commentPolicies.isEmpty {
            if commentPolicies.allSatisfy({ $0.state == .passed }) {
                add(.comments, .done, "Comments resolved")
            } else {
                add(.comments, .needsYou, open == 0 ? "Resolve comments" : open == 1 ? "Resolve 1 comment" : "Resolve \(open) comments",
                    "A policy requires resolving every comment")
            }
        } else if open > 0 {
            add(.comments, nil, open == 1 ? "1 open comment" : "\(open) open comments", required: false)
        }
        let workItemPolicies = requirements.filter { $0.name == Self.workItemLinking }
        if !workItemPolicies.isEmpty {
            let met = workItemPolicies.allSatisfy { $0.state == .passed }
            add(.workItems, met ? .done : .needsYou, met ? "Work item linked" : "Link a work item")
        }
        for (name, checks) in Self.byName(requirements.filter { $0.name != Self.commentRequirements && $0.name != Self.workItemLinking }) {
            add(.policy, checks.allSatisfy { $0.state == .passed } ? .done : nil, name)
        }

        if pr.hasConflicts {
            add(.conflicts, .failing, "Merge conflicts", "\(pr.sourceBranch) into \(pr.targetBranch)")
        }
        if let problem = pr.mergeProblem {
            add(.mergeFailed, .failing, problem.headline, problem.detail.text())
        }
        if !details.checksKnown {
            add(.unreadablePolicies, nil, "Can't read its policies",
                "Its project doesn't let you read its branch policies, so BriefBar can't tell whether it's ready")
        }

        let ordered = items.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
        self.init(items: ordered, isCurrent: details.fingerprint == pr.fingerprint)
    }

    /// Its build validation pipelines, the worst first: a failure, with where it failed once that's known; one that expired
    /// or hasn't run, and has to be queued; one that's running; or all of them passed.
    static func builds(_ builds: [Check]) -> Item {
        func names(_ checks: [Check]) -> String { checks.map(\.name).joined(separator: ", ") }
        let failed = builds.filter { $0.state == .failed }
        if !failed.isEmpty {
            let detail = failed.map { build in build.failure.map { "\(build.name) · \($0.summary)" } ?? build.name }.joined(separator: ", ")
            return Item(kind: .builds, state: .failing, label: failed.count > 1 ? "\(failed.count) builds failed" : "Build failed", detail: detail)
        }
        let expired = builds.filter { $0.state == .expired }
        if !expired.isEmpty {
            return Item(kind: .builds, state: .failing, label: expired.count > 1 ? "\(expired.count) builds expired" : "Build expired",
                        detail: names(expired) + " · queue it again")
        }
        let notRun = builds.filter { $0.state == .notRun }
        if !notRun.isEmpty {
            return Item(kind: .builds, state: .needsYou, label: notRun.count > 1 ? "\(notRun.count) builds haven't run" : "Build hasn't run",
                        detail: names(notRun) + " · queue it")
        }
        let running = builds.filter { [.running, .queued, .pending].contains($0.state) }
        if !running.isEmpty {
            let label = running.count > 1 ? "\(running.count) builds running"
                : running[0].state == .queued ? "Build queued" : "Build running"
            return Item(kind: .builds, state: .running, label: label, detail: names(running))
        }
        return Item(kind: .builds, state: .done, label: builds.count > 1 ? "Builds passed" : "Build passed", detail: names(builds))
    }

    /// The statuses other services post on it: one that failed, ones still to come, or all of them passed.
    static func checks(_ statuses: [Check]) -> Item {
        func names(_ checks: [Check]) -> String { checks.map(\.name).joined(separator: ", ") }
        let failed = statuses.filter { $0.state == .failed }
        if !failed.isEmpty {
            return Item(kind: .checks, state: .failing, label: failed.count > 1 ? "\(failed.count) checks failed" : "Check failed",
                        detail: names(failed))
        }
        let pending = statuses.filter { [.running, .queued, .pending].contains($0.state) }
        if !pending.isEmpty {
            return Item(kind: .checks, state: .running, label: pending.count > 1 ? "\(pending.count) checks running" : "Check running",
                        detail: names(pending))
        }
        return Item(kind: .checks, state: .done, label: statuses.count > 1 ? "Checks passed" : "Check passed", detail: names(statuses))
    }

    /// Policies of the same type, such as two that each require a reviewer, together: by name, in the order they came.
    private static func byName(_ checks: [Check]) -> [(name: String, checks: [Check])] {
        var grouped: [(name: String, checks: [Check])] = []
        for check in checks {
            if let index = grouped.firstIndex(where: { $0.name == check.name }) {
                grouped[index].checks.append(check)
            } else {
                grouped.append((check.name, [check]))
            }
        }
        return grouped
    }

    /// "Sam" for Sam Rivera; "Storefront Team" for the group "[Storefront]\Storefront Team".
    static func shortName(_ reviewer: Reviewer) -> String {
        guard reviewer.isGroup else { return reviewer.person.firstName }
        let name = reviewer.person.name
        if name.hasPrefix("["), let end = name.range(of: "]\\") { return String(name[end.upperBound...]) }
        return name
    }
}

extension PRReadiness.Item {
    /// Where it shows: what waits on you, what failed, what's running, what waits on someone else, what doesn't hold the
    /// pull request up, then what's done.
    var rank: Int {
        guard isRequired else { return isDone ? 5 : 4 }
        switch state {
        case .needsYou?: return 0
        case .failing?: return 1
        case .running?: return 2
        case nil: return 3
        case .done?: return 5
        }
    }
}
