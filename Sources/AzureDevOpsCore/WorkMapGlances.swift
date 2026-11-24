import BriefBarCore
import Foundation

// What My Work's Map says at a glance of a pull request and of a work item, under its title (`MapGlance`): worked out from what
// BriefBar reads already, for the Map to draw.

extension PRRecord {
    /// What My Work's Map says of it at a glance, in their order: its merge conflicts; how many of its comment threads are
    /// still active or pending, to resolve; who wants changes, or else who approved it; its builds that failed or expired, or
    /// else its checks that failed, of those a policy requires, as `PRReadiness` reads them; and that it's a draft. Comments
    /// and builds once its details are read; nothing once it's completed or abandoned, as what's done holds nothing back.
    /// Whoever's it is, yours or one you review: on yours, comments a policy requires resolving, and changes someone wants,
    /// wait on you.
    public var glances: [MapGlance] {
        let pr = pullRequest
        guard pr.status == .active else { return [] }
        let isYours = role == .author
        let readiness = details.map { PRReadiness(pr, $0) }
        var glances: [MapGlance] = []
        if pr.hasConflicts {
            glances.append(MapGlance(
                .conflicts, "Merge conflicts", state: .failing, symbol: "exclamationmark.triangle.fill",
                sentence: "Merge conflicts: \(pr.sourceBranch) into \(pr.targetBranch)"
            ))
        }
        if let details {
            let open = details.threads.filter { $0.status == "active" || $0.status == "pending" }.count
            if open > 0 {
                let required = readiness?.items.contains { $0.kind == .comments && $0.state == .needsYou } == true
                let said = open == 1 ? "1 comment to resolve" : "\(open) comments to resolve"
                glances.append(MapGlance(
                    .comments, "\(open) to resolve", count: open, state: isYours && required ? .needsYou : nil,
                    symbol: "text.bubble.fill", sentence: required ? "\(said): a policy requires resolving every comment" : said
                ))
            }
        }
        if let votes = votes(waitOnYou: isYours, readiness: readiness) {
            glances.append(votes)
        }
        if let failures = Self.failures(details) {
            glances.append(failures)
        }
        if pr.isDraft {
            glances.append(MapGlance(.draft, "Draft", symbol: "pencil.circle", sentence: "A draft"))
        }
        return glances
    }

    /// Who wants changes, you or someone else: "Priya wants changes", "You rejected it", "2 want changes"; else who approved
    /// it: "Priya approved", "You approved", "2 approved", done once the reviewers it requires approved it, as its Approved
    /// stage counts them (`isApproved`): never while a reviewer it requires, or a reviewer policy, still waits, nor from
    /// policies read before its latest push or vote, or that BriefBar can't read; until then its tooltip says what it waits
    /// for, as What's Left does. Nil while nobody voted either way.
    private func votes(waitOnYou: Bool, readiness: PRReadiness?) -> MapGlance? {
        let people = pullRequest.reviewers.filter { !$0.isGroup }
        let name = { (reviewer: Reviewer) in PullRequestStory.isMe(reviewer.person, me) ? "You" : reviewer.person.firstName }
        let wantChanges = people.filter(\.vote.wantsChanges)
        if let first = wantChanges.first(where: { $0.vote == .rejected }) ?? wantChanges.first {
            let words = if wantChanges.count > 1 {
                "\(wantChanges.count) want changes"
            } else if first.vote == .rejected {
                "\(name(first)) rejected it"
            } else {
                PullRequestStory.isMe(first.person, me) ? "You want changes" : "\(name(first)) wants changes"
            }
            let rejected = wantChanges.filter { $0.vote == .rejected }.map(\.person)
            let waiting = wantChanges.filter { $0.vote == .waitingForAuthor }.map(\.person)
            let sentence = [
                rejected.isEmpty ? nil : "Rejected by " + PullRequestStory.names(rejected, me: me),
                waiting.isEmpty ? nil : "Changes requested by " + PullRequestStory.names(waiting, me: me),
            ].compactMap { $0 }.joined(separator: " · ")
            return MapGlance(
                .votes, words, count: wantChanges.count, state: waitOnYou ? .needsYou : nil, symbol: "hand.raised.fill",
                sentence: sentence
            )
        }
        let approvals = people.filter(\.vote.isApproval)
        guard let first = approvals.first else { return nil }
        let approvedBy = "Approved by " + PullRequestStory.names(approvals.map(\.person), me: me)
        let approved = isApproved(readiness) == true
        let waiting = reviews(in: readiness).filter { !$0.isDone }
        let left = approved ? nil : (waiting.first { $0.kind == .requiredReviewers } ?? waiting.first)?.label
        return MapGlance(
            .votes, approvals.count > 1 ? "\(approvals.count) approved" : "\(name(first)) approved", count: approvals.count,
            state: approved ? .done : nil, symbol: "checkmark.circle.fill",
            sentence: left.map { "\(approvedBy) · \($0)" } ?? approvedBy
        )
    }

    /// Its builds that failed or expired, or else its checks that failed, of those a policy requires, as `PRReadiness` reads
    /// them: "Build failed", "2 builds expired", "Check failed", with what failed for its tooltip. How many, past one. Nil for
    /// none, and before its details are read.
    static func failures(_ details: PRDetails?) -> MapGlance? {
        guard let details else { return nil }
        let blocking = details.checks.filter { $0.isBlocking && $0.kind != .completion && $0.state != .notApplicable }
        let builds = blocking.filter { $0.kind == .build }
        let statuses = blocking.filter { $0.kind == .status }
        let item: PRReadiness.Item
        let count: Int
        if let read = builds.isEmpty ? nil : PRReadiness.builds(builds), read.state == .failing {
            let failed = builds.filter { $0.state == .failed }.count
            item = read
            count = failed > 0 ? failed : builds.filter { $0.state == .expired }.count
        } else if let read = statuses.isEmpty ? nil : PRReadiness.checks(statuses), read.state == .failing {
            item = read
            count = statuses.filter { $0.state == .failed }.count
        } else {
            return nil
        }
        return MapGlance(
            .builds, item.label, count: count > 1 ? count : nil, state: .failing, symbol: "xmark.circle.fill",
            sentence: item.detail.map { "\(item.label): \($0)" } ?? item.label
        )
    }
}

extension WorkItem {
    /// What My Work's Map says of it at a glance, in their order: its state, as its process names it; the hours left on it,
    /// for one that tracks them and isn't done; and, for one outside the sprint going on, where it is, as its card says it
    /// (`OutsideWork.place`): "Sprint 41", "No sprint".
    public func glances(place: String?) -> [MapGlance] {
        var glances: [MapGlance] = []
        if !state.isEmpty {
            glances.append(MapGlance(.state, state))
        }
        if !isDone, let left = remainingWork, left > 0 {
            let hours = WorkItemStory.hours(left)
            glances.append(MapGlance(.hours, "\(hours) left", symbol: "clock", sentence: "\(hours) of work left"))
        }
        if let place {
            glances.append(MapGlance(.sprint, place, symbol: "calendar", sentence: place == OutsideWork.noSprint ? "In no sprint" : "In \(place)"))
        }
        return glances
    }
}
