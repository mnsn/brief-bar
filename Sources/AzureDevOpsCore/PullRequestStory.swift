import BriefBarCore
import Foundation

/// What BriefBar can tell about a pull request beyond its row, from what it already read: where it stands, who wrote it
/// and who reviews it, how its comments and its merge stand, its branch, and the builds and checks that ran on it.
public enum PullRequestStory {
    /// One of the pull requests in your lists: you wrote it, review it or watch it, or someone sent it to you. Its row says
    /// where it stands; what was read for it, when it's there, says the rest.
    public static func mine(_ snapshot: PRSnapshot, record: PRRecord?) -> ItemStory {
        let pullRequest = record?.pullRequest
        var facts: [ItemStory.Fact] = []
        if snapshot.role != .author { facts.append(ItemStory.Fact("Author", snapshot.author)) }
        if let pullRequest {
            if let reviewers = reviewers(pullRequest.reviewers) { facts.append(ItemStory.Fact("Reviewers", reviewers)) }
        } else if !snapshot.approvals.isEmpty {
            facts.append(ItemStory.Fact("Reviewers", "Approved by " + names(snapshot.approvals)))
        }
        if let details = record?.details {
            let waiting = snapshot.pendingEvents.filter { waitingKinds.contains($0.kind) }.count
            facts.append(ItemStory.Fact("Comments", comments(details.threads, waitingOnYou: waiting)))
        }
        if let pullRequest {
            if let merge = merge(pullRequest) { facts.append(ItemStory.Fact("Merge", merge)) }
            if let branch = branch(pullRequest) { facts.append(ItemStory.Fact("Branch", branch)) }
        }

        var runs = (record?.details?.checks ?? []).compactMap { check in
            run(check, organization: snapshot.key.organization, project: snapshot.project)
        }
        if let merge = snapshot.merge { runs.append(run(merge)) }
        return ItemStory(
            sentence: sentence(snapshot.headline, snapshot.detail), date: snapshot.since, facts: facts,
            runs: runs.sorted(by: ItemStory.Run.showsFirst)
        )
    }

    /// A pull request that's linked but not in your lists, such as a teammate's on a sprint's work item. BriefBar reads only
    /// the pull request itself for these, not its comments or its checks, so where it stands is what its votes say.
    public static func others(_ pullRequest: PullRequest) -> ItemStory {
        var facts = [ItemStory.Fact("Author", pullRequest.author.name)]
        if let reviewers = reviewers(pullRequest.reviewers) { facts.append(ItemStory.Fact("Reviewers", reviewers)) }
        if let merge = merge(pullRequest) { facts.append(ItemStory.Fact("Merge", merge)) }
        if let branch = branch(pullRequest) { facts.append(ItemStory.Fact("Branch", branch)) }
        return ItemStory(sentence: standing(pullRequest), date: pullRequest.closedAt ?? pullRequest.createdAt, facts: facts)
    }

    // MARK: Where it stands

    /// "Sam Rivera replied: Could we cap it?": a row's headline and its detail, in a line.
    static func sentence(_ headline: String, _ detail: String?) -> String {
        StoryText.line([headline, detail ?? ""].filter { !$0.isEmpty }.joined(separator: ": "), limit: 160)
    }

    /// Where a pull request stands from what it says itself: whether it's closed or a draft, and its votes. "Sam wants
    /// changes", "Approved by Priya Shah", "Waiting for reviewers: Alex Kim".
    static func standing(_ pullRequest: PullRequest) -> String {
        switch pullRequest.status {
        case .completed: return "Completed: merged into \(pullRequest.targetBranch)"
        case .abandoned: return "Abandoned"
        case .other: return "Closed"
        case .active: break
        }
        if pullRequest.isDraft { return "Draft" }
        let people = Self.people(pullRequest.reviewers)
        let wantChanges = people.filter(\.vote.wantsChanges)
        if let first = wantChanges.first {
            return wantChanges.count == 1 ? "\(first.person.firstName) wants changes" : "Changes requested"
        }
        let approved = people.filter(\.vote.isApproval)
        if !approved.isEmpty, people.allSatisfy({ !$0.isRequired || $0.vote.isApproval }) {
            return "Approved by " + names(approved.map(\.person.name))
        }
        let notVoted = people.filter { $0.vote == .none && !$0.hasDeclined }.map(\.person.name)
        return notVoted.isEmpty ? "Waiting for reviewers" : "Waiting for reviewers: " + names(notVoted)
    }

    // MARK: Facts

    /// The people who review it, the required ones first, then by name. Groups, such as a team a policy adds, aren't
    /// reviewers here.
    static func people(_ reviewers: [Reviewer]) -> [Reviewer] {
        reviewers.filter { !$0.isGroup }.sorted { lhs, rhs in
            if lhs.isRequired != rhs.isRequired { return lhs.isRequired }
            return lhs.person.name.localizedCaseInsensitiveCompare(rhs.person.name) == .orderedAscending
        }
    }

    /// "Sam Rivera (required) hasn't voted · Priya Shah approved": each person's vote; nil without anyone.
    static func reviewers(_ reviewers: [Reviewer]) -> String? {
        let votes = people(reviewers).map { reviewer in
            "\(reviewer.person.name)\(reviewer.isRequired ? " (required)" : "") \(vote(reviewer))"
        }
        return votes.isEmpty ? nil : votes.joined(separator: " · ")
    }

    /// What a reviewer did: "approved", "is waiting for the author", "hasn't voted", "declined".
    static func vote(_ reviewer: Reviewer) -> String {
        if reviewer.hasDeclined { return "declined" }
        switch reviewer.vote {
        case .approved: return "approved"
        case .approvedWithSuggestions: return "approved with suggestions"
        case .waitingForAuthor: return "is waiting for the author"
        case .rejected: return "rejected"
        case .none: return "hasn't voted"
        }
    }

    /// What waits on you among what needs you: a comment, a reply or a mention, and a vote that wants changes; not a review
    /// request, new commits or a message about it.
    static let waitingKinds: Set<PREvent.Kind> = [.mention, .reply, .comment, .changesRequested, .rejected]

    /// "3 open threads · 2 wait on you": how many of its threads are active or pending, and how many things wait on you.
    static func comments(_ threads: [ReviewThread], waitingOnYou waiting: Int) -> String {
        let open = threads.filter { $0.status == "active" || $0.status == "pending" }.count
        var said = switch open {
        case 0: "None open"
        case 1: "1 open thread"
        default: "\(open) open threads"
        }
        if waiting > 0 { said += waiting == 1 ? " · 1 waits on you" : " · \(waiting) wait on you" }
        return said
    }

    /// "Conflicts with main · Completes by itself once it can": how an active pull request's merge stands; nil for one
    /// that's closed, or when there's nothing to say.
    static func merge(_ pullRequest: PullRequest) -> String? {
        guard pullRequest.status == .active else { return nil }
        let said = [
            pullRequest.hasConflicts ? "Conflicts with \(pullRequest.targetBranch)" : nil,
            pullRequest.isDraft ? "Draft" : nil,
            pullRequest.autoComplete ? "Completes by itself once it can" : nil,
        ].compactMap { $0 }
        return said.isEmpty ? nil : said.joined(separator: " · ")
    }

    /// "fix-total → main": the branch it merges, and into which.
    static func branch(_ pullRequest: PullRequest) -> String? {
        guard !pullRequest.sourceBranch.isEmpty else { return nil }
        return pullRequest.targetBranch.isEmpty ? pullRequest.sourceBranch : "\(pullRequest.sourceBranch) → \(pullRequest.targetBranch)"
    }

    /// "Sam Rivera", "Sam Rivera and Priya Shah", "Sam Rivera, Priya Shah and Alex Kim"; past `limit`, "and 2 more".
    static func names(_ names: [String], limit: Int = 3) -> String {
        if names.count > limit { return names.prefix(limit).joined(separator: ", ") + " and \(names.count - limit) more" }
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Runs

    /// A build or a status check that validates the pull request, as a run; nil for any other policy, and for one that
    /// doesn't apply to it.
    static func run(_ check: Check, organization: String, project: String) -> ItemStory.Run? {
        guard check.kind == .build || check.kind == .status, check.state != .notApplicable else { return nil }
        let (state, status): (ItemState?, String) = switch check.state {
        case .passed: (.done, "Passed")
        case .failed: (.failing, check.failure.map { "Failed at \($0.step)" } ?? "Failed")
        case .running: (.running, "Running")
        case .queued: (.running, "Queued")
        case .expired: (nil, "Expired: it has to run again")
        case .notRun: (nil, "Not run")
        case .pending, .notApplicable: (nil, "Waiting")
        }
        return ItemStory.Run(
            name: check.name, state: state, status: status, detail: check.state == .failed ? firstError(check.failure) : nil,
            url: check.buildId.map { ADOEndpoint.buildPage(organization: organization, project: project, buildId: $0) },
            date: check.completedAt
        )
    }

    /// The pipelines that ran after it merged, as one run: the one that failed or waits, or all of them while they run
    /// and once they passed.
    static func run(_ merge: MergeSummary) -> ItemStory.Run {
        let (state, status): (ItemState?, String) = switch merge.outcome {
        case .failed: (.failing, merge.failure.map { "Failed at \($0.step)" } ?? "Failed")
        case .waiting: (nil, merge.stage.map { "Waiting for approval to \($0)" } ?? "Waiting for approval")
        case .running: (.running, "Running")
        case .passed: (.done, "Passed")
        }
        return ItemStory.Run(
            name: merge.pipeline ?? "Pipelines after merge", state: state, status: status,
            detail: merge.outcome == .failed ? firstError(merge.failure) : nil, url: merge.runURL, date: merge.since
        )
    }

    /// The first error where a run failed, in a line.
    static func firstError(_ failure: PipelineFailure?) -> String? {
        guard let message = failure?.message else { return nil }
        let line = StoryText.line(message, limit: 200)
        return line.isEmpty ? nil : line
    }
}
