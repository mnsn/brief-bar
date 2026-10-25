import BriefBarCore
import Foundation
import Testing
@testable import GitHubCore

@Suite struct ClassifierTests {
    private func classify(_ pullRequest: GitHubPullRequest, role: GitHubPRRole = .author) -> GitHubPRSnapshot {
        GitHubClassifier.classify(pullRequest, role: role)
    }

    @Test func aReviewRequestIsToReviewWhateverItsState() {
        let snapshot = classify(Fixture.make(isDraft: true, decision: .changesRequested, conflicts: true, checks: .failing), role: .reviewer)
        #expect(snapshot.group == .toReview)
        #expect(snapshot.reason == .reviewRequested)
        #expect(snapshot.headline == "Review requested")
        #expect(snapshot.detail == "By priya")
        #expect(classify(Fixture.make(author: nil), role: .reviewer).detail == nil)
    }

    @Test func aDraftWaitsEvenWhenSomethingIsWrong() {
        let snapshot = classify(Fixture.make(isDraft: true, decision: .changesRequested, conflicts: true, checks: .failing))
        #expect(snapshot.group == .waiting)
        #expect(snapshot.reason == .draft)
        #expect(snapshot.headline == "Draft")
    }

    @Test func failingChecksComeBeforeReviews() {
        let snapshot = classify(Fixture.make(decision: .changesRequested, checks: .failing))
        #expect(snapshot.group == .failing)
        #expect(snapshot.reason == .checksFailed)
        #expect(snapshot.headline == "Checks failing")
        #expect(classify(Fixture.make(conflicts: true, checks: .failing)).headline == "Checks failing · merge conflicts")
    }

    @Test func conflictsAreFailing() {
        let snapshot = classify(Fixture.make(decision: .approved, conflicts: true, checks: .passing))
        #expect(snapshot.group == .failing)
        #expect(snapshot.reason == .conflicts)
        #expect(snapshot.headline == "Merge conflicts")
    }

    @Test func changesRequestedNamesTheReviewers() {
        let reviews = [
            GitHubPullRequest.Review(reviewer: "sam", state: .changesRequested),
            GitHubPullRequest.Review(reviewer: "lee", state: .approved),
            GitHubPullRequest.Review(reviewer: "sam", state: .changesRequested),
            GitHubPullRequest.Review(reviewer: "kai", state: .changesRequested),
        ]
        let snapshot = classify(Fixture.make(decision: .changesRequested, reviews: reviews))
        #expect(snapshot.group == .changesRequested)
        #expect(snapshot.reason == .changesRequested)
        #expect(snapshot.headline == "Changes requested")
        #expect(snapshot.detail == "By sam and kai")
        #expect(classify(Fixture.make(decision: .changesRequested)).detail == nil)
    }

    @Test func changesRequestedComesBeforeRunningChecks() {
        #expect(classify(Fixture.make(decision: .changesRequested, checks: .running)).group == .changesRequested)
    }

    /// Without required reviews, GitHub gives no decision: the reviews decide.
    @Test func withoutADecisionTheReviewsDecide() {
        let changes = classify(Fixture.make(reviews: [.init(reviewer: "sam", state: .changesRequested), .init(reviewer: "lee", state: .approved)]))
        #expect(changes.group == .changesRequested)
        let approved = classify(Fixture.make(reviews: [.init(reviewer: "lee", state: .approved)]))
        #expect(approved.group == .ready)
        #expect(approved.detail == "By lee")
    }

    /// GitHub's decision wins over individual reviews: an approval after changes were requested, say.
    @Test func theDecisionWinsOverReviews() {
        let snapshot = classify(Fixture.make(decision: .approved, reviews: [.init(reviewer: "sam", state: .changesRequested)]))
        #expect(snapshot.group == .ready)
        #expect(classify(Fixture.make(decision: .reviewRequired, reviews: [.init(reviewer: "lee", state: .approved)])).group == .waiting)
    }

    @Test func runningChecksWaitEvenWhenApproved() {
        let snapshot = classify(Fixture.make(decision: .approved, checks: .running))
        #expect(snapshot.group == .waiting)
        #expect(snapshot.reason == .checksRunning)
        #expect(snapshot.headline == "Checks running")
    }

    @Test func approvedIsReady() {
        let snapshot = classify(Fixture.make(decision: .approved, checks: .passing))
        #expect(snapshot.group == .ready)
        #expect(snapshot.reason == .approved)
        #expect(snapshot.headline == "Approved")
        #expect(snapshot.detail == nil)
    }

    @Test func otherwiseItWaitsForReview() {
        for decision in [nil, GitHubPullRequest.ReviewDecision.reviewRequired] {
            let snapshot = classify(Fixture.make(decision: decision, checks: .passing))
            #expect(snapshot.group == .waiting)
            #expect(snapshot.reason == .waitingForReview)
            #expect(snapshot.headline == "Waiting for review")
        }
    }

    @Test func eachPullRequestOnceYoursFirst() {
        let shared = Fixture.make(7, decision: .approved, id: "PR_shared")
        let snapshots = GitHubClassifier.snapshots(reviewing: [shared, Fixture.make(8)], authored: [shared])
        #expect(snapshots.count == 2)
        #expect(snapshots.first { $0.id == "PR_shared" }?.role == .author)
        #expect(snapshots.first { $0.id == "PR_shared" }?.group == .ready)
        #expect(snapshots.first { $0.id == "PR_8" }?.role == .reviewer)
    }

    @Test func sortsByGroupThenMostRecent() {
        let snapshots = GitHubClassifier.snapshots(
            reviewing: [Fixture.make(1, updated: t(0)), Fixture.make(2, updated: t(minute))],
            authored: [
                Fixture.make(3, updated: t(5 * minute)),
                Fixture.make(4, updated: t(hour), checks: .failing),
                Fixture.make(5, updated: t(2 * minute), decision: .approved),
                Fixture.make(6, updated: t(3 * minute), decision: .changesRequested),
                Fixture.make(7, updated: t(hour), checks: .failing),
            ]
        )
        #expect(snapshots.map(\.id) == ["PR_2", "PR_1", "PR_6", "PR_4", "PR_7", "PR_5", "PR_3"])
    }

    @Test func namesPeople() {
        #expect(GitHubClassifier.names([]) == "")
        #expect(GitHubClassifier.names(["a"]) == "a")
        #expect(GitHubClassifier.names(["a", "b"]) == "a and b")
        #expect(GitHubClassifier.names(["a", "b", "c"]) == "a, b and c")
        #expect(GitHubClassifier.names(["a", "b", "c", "d", "e"]) == "a, b and 3 others")
    }

    @Test func groupsCountInTheSharedStates() {
        #expect(GitHubPRGroup.toReview.state == .needsYou)
        #expect(GitHubPRGroup.changesRequested.state == .needsYou)
        #expect(GitHubPRGroup.failing.state == .failing)
        #expect(GitHubPRGroup.ready.state == .done)
        #expect(GitHubPRGroup.waiting.state == nil)
        #expect(GitHubPRGroup.allCases.sorted() == GitHubPRGroup.allCases)
    }

    @Test func countsByGroupAndByState() {
        let snapshots = GitHubClassifier.snapshots(
            reviewing: [Fixture.make(1), Fixture.make(2)],
            authored: [Fixture.make(3, checks: .failing), Fixture.make(4, decision: .changesRequested), Fixture.make(5), Fixture.make(6, decision: .approved)]
        )
        let counts = GitHubGroupCounts(snapshots)
        #expect(counts.toReview == 2)
        #expect(counts.changesRequested == 1)
        #expect(counts.failing == 1)
        #expect(counts.ready == 1)
        #expect(counts.waiting == 1)
        #expect(counts.total == 6)
        #expect(counts.needsYou == 3)
        #expect(counts.states.needsYou == 3)
        #expect(counts.states.failing == 1)
        #expect(counts.states.done == 1)
        #expect(counts.states.running == 0)
    }

    @Test func briefSentences() {
        let sam = GitHubPullRequest.Review(reviewer: "sam", state: .changesRequested)
        func sentence(_ pullRequest: GitHubPullRequest, role: GitHubPRRole = .author) -> String {
            classify(pullRequest, role: role).briefSentence
        }
        #expect(sentence(Fixture.make(1), role: .reviewer) == "priya asks for your review on “Pull request 1”.")
        #expect(sentence(Fixture.make(1, author: nil), role: .reviewer) == "Your review is requested on “Pull request 1”.")
        #expect(sentence(Fixture.make(1, decision: .changesRequested, reviews: [sam])) == "sam requested changes on “Pull request 1”.")
        #expect(sentence(Fixture.make(1, decision: .changesRequested)) == "Changes are requested on “Pull request 1”.")
        #expect(sentence(Fixture.make(1, checks: .failing)) == "Checks are failing on “Pull request 1”.")
        #expect(sentence(Fixture.make(1, conflicts: true)) == "“Pull request 1” has merge conflicts.")
        #expect(sentence(Fixture.make(1, decision: .approved)) == "“Pull request 1” is approved.")
    }

    @Test func readsWhatTheQueryAnswers() throws {
        let pullRequest = try Fixture.decoded(Fixture.pullRequest(
            12, repository: "octo/web", author: "priya", reviewDecision: "CHANGES_REQUESTED", mergeable: "CONFLICTING", rollup: "ERROR",
            reviews: [("CHANGES_REQUESTED", "sam"), ("APPROVED", nil), ("DISMISSED", "lee")]
        ))
        #expect(pullRequest.id == "PR_octo/web_12")
        #expect(pullRequest.reference == "octo/web#12")
        #expect(pullRequest.url.absoluteString == "https://github.com/octo/web/pull/12")
        #expect(pullRequest.author == "priya")
        #expect(pullRequest.reviewDecision == .changesRequested)
        #expect(pullRequest.hasConflicts)
        #expect(pullRequest.checks == .failing)
        #expect(pullRequest.reviews == [.init(reviewer: "sam", state: .changesRequested), .init(reviewer: nil, state: .approved)])
        #expect(pullRequest.updatedAt == t(0))
    }

    @Test func readsChecksAndUnknownValues() throws {
        #expect(GitHubPullRequest.Checks(rollup: "SUCCESS") == .passing)
        #expect(GitHubPullRequest.Checks(rollup: "FAILURE") == .failing)
        #expect(GitHubPullRequest.Checks(rollup: "ERROR") == .failing)
        #expect(GitHubPullRequest.Checks(rollup: "PENDING") == .running)
        #expect(GitHubPullRequest.Checks(rollup: "EXPECTED") == .running)
        #expect(GitHubPullRequest.Checks(rollup: "SOMETHING_NEW") == nil)
        #expect(GitHubPullRequest.Checks(rollup: nil) == nil)

        let unknown = try Fixture.decoded(Fixture.pullRequest(3, author: nil, reviewDecision: "SOMETHING_NEW", mergeable: "UNKNOWN"))
        #expect(unknown.author == nil)
        #expect(unknown.reviewDecision == nil)
        #expect(!unknown.hasConflicts)
        #expect(unknown.checks == nil)
        #expect(classify(unknown).group == .waiting)
    }
}
