import BriefBarCore
import Foundation

extension GitHubPRSnapshot {
    /// What BriefBar can tell about it beyond its row, from what its query read: where it stands, its reviews, how its
    /// merge stands, and its checks; and, saying less, who wrote it and its branch.
    public var story: ItemStory {
        var facts: [ItemStory.Fact] = []
        if let reviews = latestReviews { facts.append(ItemStory.Fact("Reviews", reviews)) }
        let merge = [pullRequest.hasConflicts ? "Conflicts" : nil, pullRequest.isDraft ? "Draft" : nil].compactMap { $0 }
        if !merge.isEmpty { facts.append(ItemStory.Fact("Merge", merge.joined(separator: " · "))) }
        var more: [ItemStory.Fact] = []
        if role == .reviewer, let author = pullRequest.author { more.append(ItemStory.Fact("Author", author)) }
        if let branch = pullRequest.branch, !branch.isEmpty { more.append(ItemStory.Fact("Branch", branch)) }
        let sentence = [headline, detail ?? ""].filter { !$0.isEmpty }.joined(separator: ": ")
        return ItemStory(
            sentence: StoryText.line(sentence, limit: 160), date: since, facts: facts, more: more, runs: checksRun.map { [$0] } ?? [],
            waits: wait.map { [$0] } ?? []
        )
    }

    /// Who it waits on, and for what, by why it's where it is in the list, as Azure DevOps' do (`PullRequestWait`): "you,
    /// to review priya's #12", "you, to merge #12", "the checks on #12". What waits on you always says what to do.
    public var wait: ItemStory.Wait? {
        let number = "#\(pullRequest.number)"
        let yours = role == .author
        let author = pullRequest.author ?? "its author"
        let whose = yours ? "your \(number)" : "\(author)'s \(number)"
        func authors(_ what: String) -> ItemStory.Wait {
            yours ? ItemStory.Wait(.you, "you, \(what)") : ItemStory.Wait(.people, "\(author), \(what)")
        }
        switch reason {
        case .reviewRequested: return ItemStory.Wait(.you, "you, to review \(whose)")
        case .changesRequested: return authors("to make the changes asked for on \(number)")
        case .checksFailed: return authors("to fix \(number)'s checks")
        case .conflicts: return authors("to resolve \(number)'s conflicts")
        case .approved: return authors("to merge \(number)")
        case .draft: return authors("to mark \(number) ready for review")
        case .checksRunning: return ItemStory.Wait(.people, "the checks on \(number)")
        case .waitingForReview: return ItemStory.Wait(.people, "reviewers of \(whose)")
        }
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
