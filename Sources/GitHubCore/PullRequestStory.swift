import BriefBarCore
import Foundation

extension GitHubPRSnapshot {
    /// What BriefBar can tell about it beyond its row, from what its query read: where it stands, who wrote it, its
    /// reviews, how its merge stands, its branch, and its checks.
    public var story: ItemStory {
        var facts: [ItemStory.Fact] = []
        if role == .reviewer, let author = pullRequest.author { facts.append(ItemStory.Fact("Author", author)) }
        if let reviews = latestReviews { facts.append(ItemStory.Fact("Reviews", reviews)) }
        let merge = [pullRequest.hasConflicts ? "Conflicts" : nil, pullRequest.isDraft ? "Draft" : nil].compactMap { $0 }
        if !merge.isEmpty { facts.append(ItemStory.Fact("Merge", merge.joined(separator: " · "))) }
        if let branch = pullRequest.branch, !branch.isEmpty { facts.append(ItemStory.Fact("Branch", branch)) }
        let sentence = [headline, detail ?? ""].filter { !$0.isEmpty }.joined(separator: ": ")
        return ItemStory(sentence: StoryText.line(sentence, limit: 160), date: since, facts: facts, runs: checksRun.map { [$0] } ?? [])
    }

    /// "alice approved · bob requested changes": each reviewer's latest review that approves or requests changes; nil
    /// without any.
    private var latestReviews: String? {
        var latest: [(reviewer: String, state: GitHubPullRequest.Review.State)] = []
        for review in pullRequest.reviews {
            guard let reviewer = review.reviewer, !reviewer.isEmpty else { continue }
            if let index = latest.firstIndex(where: { $0.reviewer == reviewer }) {
                latest[index].state = review.state
            } else {
                latest.append((reviewer, review.state))
            }
        }
        guard !latest.isEmpty else { return nil }
        return latest.map { "\($0.reviewer) \($0.state == .approved ? "approved" : "requested changes")" }.joined(separator: " · ")
    }

    /// Its latest commit's checks, all together, as a run that opens its Checks tab; nil when nothing checks it.
    private var checksRun: ItemStory.Run? {
        guard let checks = pullRequest.checks else { return nil }
        let (state, status): (ItemState, String) = switch checks {
        case .passing: (.done, "Passing")
        case .failing: (.failing, "Failing")
        case .running: (.running, "Running")
        }
        return ItemStory.Run(name: "Checks", state: state, status: status, url: pullRequest.url.appendingPathComponent("checks"))
    }
}
