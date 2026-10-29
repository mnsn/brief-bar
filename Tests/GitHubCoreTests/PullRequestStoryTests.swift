import BriefBarCore
import Foundation
import Testing
@testable import GitHubCore

/// What a GitHub pull request's story says, from what its query read.
@Suite struct PullRequestStoryTests {
    private func classify(_ pullRequest: GitHubPullRequest, role: GitHubPRRole = .author) -> GitHubPRSnapshot {
        GitHubClassifier.classify(pullRequest, role: role)
    }

    @Test func itsSentenceIsItsRowsHeadlineAndDetailInALine() {
        let review = classify(Fixture.make(updated: t(-hour)), role: .reviewer)
        #expect(review.story.sentence == "Review requested: By priya")
        #expect(review.story.date == t(-hour))
        #expect(classify(Fixture.make(decision: .approved, reviews: [.init(reviewer: "sam", state: .approved)])).story.sentence
            == "Approved: By sam")
        #expect(classify(Fixture.make()).story.sentence == "Waiting for review")

        var long = review
        long.detail = String(repeating: "A long line. ", count: 15) + "\nAnd another."
        let sentence = long.story.sentence
        #expect(sentence.hasPrefix("Review requested: A long line. A long line."))
        #expect(sentence.count <= 160)
        #expect(sentence.hasSuffix("…"))
        #expect(!sentence.contains("\n"))
    }

    /// Who it waits on, by why it's in the list: you, saying what to do, or others; and which pull request it is.
    @Test func itSaysWhoItWaitsOn() {
        func said(_ pullRequest: GitHubPullRequest, role: GitHubPRRole = .author) -> ItemStory.Wait? {
            classify(pullRequest, role: role).wait.map { ItemStory.Wait($0.who, $0.text) }
        }
        #expect(said(Fixture.make(12), role: .reviewer) == ItemStory.Wait(.you, "you, to review priya's #12"))
        #expect(said(Fixture.make(12, decision: .changesRequested)) == ItemStory.Wait(.you, "you, to make the changes asked for on #12"))
        #expect(said(Fixture.make(12, checks: .failing)) == ItemStory.Wait(.you, "you, to fix #12's checks"))
        #expect(said(Fixture.make(12, conflicts: true)) == ItemStory.Wait(.you, "you, to resolve #12's conflicts"))
        #expect(said(Fixture.make(12, decision: .approved)) == ItemStory.Wait(.you, "you, to merge #12"))
        #expect(said(Fixture.make(12, isDraft: true)) == ItemStory.Wait(.you, "you, to mark #12 ready for review"))
        #expect(said(Fixture.make(12, checks: .running))?.who == .people)
        #expect(said(Fixture.make(12)) == ItemStory.Wait(.people, "reviewers of your #12"))
        // Its story says so, about it.
        let review = classify(Fixture.make(12), role: .reviewer)
        #expect(review.story.waits == [review.wait!])
        #expect(review.wait?.about == .gitHubPullRequest(repository: "octo/app", number: 12))

        // Two numbered 12, in two repositories, are both said, each with its repository.
        var other = Fixture.make(12, decision: .approved)
        other.repository = "octo/web"
        let waits = ItemStory.Wait.ordered([classify(Fixture.make(12, decision: .approved)).wait!, classify(other).wait!])
        #expect(ItemStory.Wait.said(waits).map(\.text) == ["you, to merge #12 (octo/app)", "you, to merge #12 (octo/web)"])
    }

    @Test func factsSayItsReviewsAndMergeThenWhoWroteItAndItsBranch() {
        var pullRequest = Fixture.make(isDraft: true, conflicts: true, reviews: [
            .init(reviewer: "alice", state: .changesRequested),
            .init(reviewer: "bob", state: .changesRequested),
            .init(reviewer: nil, state: .approved),
            .init(reviewer: "alice", state: .approved),
        ])
        pullRequest.branch = "priya/tax-rounding"
        let reviewing = classify(pullRequest, role: .reviewer).story
        #expect(reviewing.facts == [
            ItemStory.Fact("Reviews", "alice approved · bob requested changes"),
            ItemStory.Fact("Merge", "Conflicts · Draft"),
        ])
        // Who wrote it and its branch say less: they show with the rest.
        #expect(reviewing.more == [ItemStory.Fact("Author", "priya"), ItemStory.Fact("Branch", "priya/tax-rounding")])

        // Yours has no author; and each fact shows only when it says something.
        #expect(classify(pullRequest).story.facts.map(\.label) == ["Reviews", "Merge"])
        #expect(classify(pullRequest).story.more.map(\.label) == ["Branch"])
        #expect(classify(Fixture.make()).story.facts.isEmpty)
        #expect(classify(Fixture.make(author: nil), role: .reviewer).story.facts.isEmpty)
        #expect(classify(Fixture.make(author: nil), role: .reviewer).story.more.isEmpty)
        #expect(classify(Fixture.make(conflicts: true)).story.facts == [ItemStory.Fact("Merge", "Conflicts")])
    }

    @Test func itsChecksAreARunThatOpensTheirTab() {
        func runs(_ checks: GitHubPullRequest.Checks?) -> [ItemStory.Run] {
            classify(Fixture.make(checks: checks)).story.runs
        }
        let url = URL(string: "https://github.com/octo/app/pull/1/checks")
        #expect(runs(.passing) == [ItemStory.Run(name: "Checks", state: .done, status: "Passing", url: url)])
        #expect(runs(.failing) == [ItemStory.Run(name: "Checks", state: .failing, status: "Failing", url: url)])
        #expect(runs(.running) == [ItemStory.Run(name: "Checks", state: .running, status: "Running", url: url)])
        #expect(runs(nil).isEmpty)
    }
}
