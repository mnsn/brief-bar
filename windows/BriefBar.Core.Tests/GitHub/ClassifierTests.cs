using BriefBar.Core.GitHub;

namespace BriefBar.Core.Tests.GitHub;

/// Where each pull request goes, and why: the Swift tests' `ClassifierTests` and `BranchTests`.
public sealed class ClassifierTests
{
    static GitHubPRSnapshot Classify(GitHubPullRequest pullRequest, GitHubPRRole role = GitHubPRRole.Author) =>
        GitHubClassifier.Classify(pullRequest: pullRequest, role: role);

    static GitHubReview Review(string reviewer, GitHubReviewState state) => new(Reviewer: reviewer, State: state);

    [Fact]
    public void AReviewRequestIsToReviewWhateverItsState()
    {
        var snapshot = Classify(
            pullRequest: GitHubFixture.Make(isDraft: true, decision: GitHubReviewDecision.ChangesRequested, conflicts: true, checks: GitHubChecks.Failing),
            role: GitHubPRRole.Reviewer);
        Assert.Equal(expected: GitHubPRGroup.ToReview, actual: snapshot.Group);
        Assert.Equal(expected: GitHubPRReason.ReviewRequested, actual: snapshot.Reason);
        Assert.Equal(expected: "Review requested", actual: snapshot.Headline);
        Assert.Equal(expected: "By priya", actual: snapshot.Detail);
        Assert.Null(@object: Classify(pullRequest: GitHubFixture.Make(author: null), role: GitHubPRRole.Reviewer).Detail);
    }

    [Fact]
    public void ADraftWaitsEvenWhenSomethingIsWrong()
    {
        var snapshot = Classify(pullRequest: GitHubFixture.Make(isDraft: true, decision: GitHubReviewDecision.ChangesRequested, conflicts: true, checks: GitHubChecks.Failing));
        Assert.Equal(expected: GitHubPRGroup.Waiting, actual: snapshot.Group);
        Assert.Equal(expected: GitHubPRReason.Draft, actual: snapshot.Reason);
        Assert.Equal(expected: "Draft", actual: snapshot.Headline);
    }

    [Fact]
    public void FailingChecksComeBeforeReviews()
    {
        var snapshot = Classify(pullRequest: GitHubFixture.Make(decision: GitHubReviewDecision.ChangesRequested, checks: GitHubChecks.Failing));
        Assert.Equal(expected: GitHubPRGroup.Failing, actual: snapshot.Group);
        Assert.Equal(expected: GitHubPRReason.ChecksFailed, actual: snapshot.Reason);
        Assert.Equal(expected: "Checks failing", actual: snapshot.Headline);
        Assert.Equal(expected: "Checks failing · merge conflicts", actual: Classify(pullRequest: GitHubFixture.Make(conflicts: true, checks: GitHubChecks.Failing)).Headline);
    }

    [Fact]
    public void ConflictsAreFailing()
    {
        var snapshot = Classify(pullRequest: GitHubFixture.Make(decision: GitHubReviewDecision.Approved, conflicts: true, checks: GitHubChecks.Passing));
        Assert.Equal(expected: GitHubPRGroup.Failing, actual: snapshot.Group);
        Assert.Equal(expected: GitHubPRReason.Conflicts, actual: snapshot.Reason);
        Assert.Equal(expected: "Merge conflicts", actual: snapshot.Headline);
    }

    [Fact]
    public void ChangesRequestedNamesTheReviewers()
    {
        GitHubReview[] reviews =
        [
            Review(reviewer: "sam", state: GitHubReviewState.ChangesRequested),
            Review(reviewer: "lee", state: GitHubReviewState.Approved),
            Review(reviewer: "sam", state: GitHubReviewState.ChangesRequested),
            Review(reviewer: "kai", state: GitHubReviewState.ChangesRequested),
        ];
        var snapshot = Classify(pullRequest: GitHubFixture.Make(decision: GitHubReviewDecision.ChangesRequested, reviews: reviews));
        Assert.Equal(expected: GitHubPRGroup.ChangesRequested, actual: snapshot.Group);
        Assert.Equal(expected: GitHubPRReason.ChangesRequested, actual: snapshot.Reason);
        Assert.Equal(expected: "Changes requested", actual: snapshot.Headline);
        Assert.Equal(expected: "By sam and kai", actual: snapshot.Detail);
        Assert.Null(@object: Classify(pullRequest: GitHubFixture.Make(decision: GitHubReviewDecision.ChangesRequested)).Detail);
    }

    [Fact]
    public void ChangesRequestedComesBeforeRunningChecks() =>
        Assert.Equal(
            expected: GitHubPRGroup.ChangesRequested,
            actual: Classify(pullRequest: GitHubFixture.Make(decision: GitHubReviewDecision.ChangesRequested, checks: GitHubChecks.Running)).Group);

    /// Without required reviews, GitHub gives no decision: the reviews decide.
    [Fact]
    public void WithoutADecisionTheReviewsDecide()
    {
        var changes = Classify(pullRequest: GitHubFixture.Make(reviews:
            [Review(reviewer: "sam", state: GitHubReviewState.ChangesRequested), Review(reviewer: "lee", state: GitHubReviewState.Approved)]));
        Assert.Equal(expected: GitHubPRGroup.ChangesRequested, actual: changes.Group);
        var approved = Classify(pullRequest: GitHubFixture.Make(reviews: [Review(reviewer: "lee", state: GitHubReviewState.Approved)]));
        Assert.Equal(expected: GitHubPRGroup.Ready, actual: approved.Group);
        Assert.Equal(expected: "By lee", actual: approved.Detail);
    }

    /// GitHub's decision wins over individual reviews: an approval after changes were requested, say.
    [Fact]
    public void TheDecisionWinsOverReviews()
    {
        var snapshot = Classify(pullRequest: GitHubFixture.Make(decision: GitHubReviewDecision.Approved, reviews: [Review(reviewer: "sam", state: GitHubReviewState.ChangesRequested)]));
        Assert.Equal(expected: GitHubPRGroup.Ready, actual: snapshot.Group);
        Assert.Equal(
            expected: GitHubPRGroup.Waiting,
            actual: Classify(pullRequest: GitHubFixture.Make(decision: GitHubReviewDecision.ReviewRequired, reviews: [Review(reviewer: "lee", state: GitHubReviewState.Approved)])).Group);
    }

    [Fact]
    public void RunningChecksWaitEvenWhenApproved()
    {
        var snapshot = Classify(pullRequest: GitHubFixture.Make(decision: GitHubReviewDecision.Approved, checks: GitHubChecks.Running));
        Assert.Equal(expected: GitHubPRGroup.Waiting, actual: snapshot.Group);
        Assert.Equal(expected: GitHubPRReason.ChecksRunning, actual: snapshot.Reason);
        Assert.Equal(expected: "Checks running", actual: snapshot.Headline);
    }

    [Fact]
    public void ApprovedIsReady()
    {
        var snapshot = Classify(pullRequest: GitHubFixture.Make(decision: GitHubReviewDecision.Approved, checks: GitHubChecks.Passing));
        Assert.Equal(expected: GitHubPRGroup.Ready, actual: snapshot.Group);
        Assert.Equal(expected: GitHubPRReason.Approved, actual: snapshot.Reason);
        Assert.Equal(expected: "Approved", actual: snapshot.Headline);
        Assert.Null(@object: snapshot.Detail);
    }

    [Theory]
    [InlineData(null)]
    [InlineData(GitHubReviewDecision.ReviewRequired)]
    public void OtherwiseItWaitsForReview(GitHubReviewDecision? decision)
    {
        var snapshot = Classify(pullRequest: GitHubFixture.Make(decision: decision, checks: GitHubChecks.Passing));
        Assert.Equal(expected: GitHubPRGroup.Waiting, actual: snapshot.Group);
        Assert.Equal(expected: GitHubPRReason.WaitingForReview, actual: snapshot.Reason);
        Assert.Equal(expected: "Waiting for review", actual: snapshot.Headline);
    }

    [Fact]
    public void EachPullRequestOnceYoursFirst()
    {
        var shared = GitHubFixture.Make(number: 7, decision: GitHubReviewDecision.Approved, id: "PR_shared");
        var snapshots = GitHubClassifier.Snapshots(reviewing: [shared, GitHubFixture.Make(number: 8)], authored: [shared]);
        Assert.Equal(expected: 2, actual: snapshots.Count);
        var yours = Assert.Single(collection: snapshots, predicate: snapshot => snapshot.Id == "PR_shared");
        Assert.Equal(expected: GitHubPRRole.Author, actual: yours.Role);
        Assert.Equal(expected: GitHubPRGroup.Ready, actual: yours.Group);
        Assert.Equal(expected: GitHubPRRole.Reviewer, actual: Assert.Single(collection: snapshots, predicate: snapshot => snapshot.Id == "PR_8").Role);
    }

    [Fact]
    public void SortsByGroupThenMostRecent()
    {
        var snapshots = GitHubClassifier.Snapshots(
            reviewing: [GitHubFixture.Make(number: 1, updated: TestTimes.T(seconds: 0)), GitHubFixture.Make(number: 2, updated: TestTimes.T(seconds: GitHubFixture.Minute))],
            authored:
            [
                GitHubFixture.Make(number: 3, updated: TestTimes.T(seconds: 5 * GitHubFixture.Minute)),
                GitHubFixture.Make(number: 4, updated: TestTimes.T(seconds: GitHubFixture.Hour), checks: GitHubChecks.Failing),
                GitHubFixture.Make(number: 5, updated: TestTimes.T(seconds: 2 * GitHubFixture.Minute), decision: GitHubReviewDecision.Approved),
                GitHubFixture.Make(number: 6, updated: TestTimes.T(seconds: 3 * GitHubFixture.Minute), decision: GitHubReviewDecision.ChangesRequested),
                GitHubFixture.Make(number: 7, updated: TestTimes.T(seconds: GitHubFixture.Hour), checks: GitHubChecks.Failing),
            ]);
        Assert.Equal(expected: ["PR_2", "PR_1", "PR_6", "PR_4", "PR_7", "PR_5", "PR_3"], actual: snapshots.Select(selector: snapshot => snapshot.Id));
    }

    /// As Windows writes a list (`ListWords`), where the Mac writes "a, b and c".
    [Fact]
    public void NamesPeople()
    {
        Assert.Equal(expected: string.Empty, actual: GitHubClassifier.Names(names: []));
        Assert.Equal(expected: "a", actual: GitHubClassifier.Names(names: ["a"]));
        Assert.Equal(expected: "a and b", actual: GitHubClassifier.Names(names: ["a", "b"]));
        Assert.Equal(expected: "a, b, and c", actual: GitHubClassifier.Names(names: ["a", "b", "c"]));
        Assert.Equal(expected: "a, b, and 3 others", actual: GitHubClassifier.Names(names: ["a", "b", "c", "d", "e"]));
    }

    [Fact]
    public void GroupsCountInTheSharedStates()
    {
        Assert.Equal(expected: ItemState.NeedsYou, actual: GitHubPRGroup.ToReview.State());
        Assert.Equal(expected: ItemState.NeedsYou, actual: GitHubPRGroup.ChangesRequested.State());
        Assert.Equal(expected: ItemState.Failing, actual: GitHubPRGroup.Failing.State());
        Assert.Equal(expected: ItemState.Done, actual: GitHubPRGroup.Ready.State());
        Assert.Null(@object: GitHubPRGroup.Waiting.State());
        Assert.Equal(expected: GitHubPRGroups.All.Order(), actual: GitHubPRGroups.All);
        Assert.Equal(
            expected: ["To review", "Changes requested", "Failing", "Ready to merge", "Waiting"],
            actual: GitHubPRGroups.All.Select(selector: group => group.Title()));
        Assert.Equal(
            expected: ["toReview", "changesRequested", "failing", "ready", "waiting"],
            actual: GitHubPRGroups.All.Select(selector: group => group.RawValue()));
    }

    [Fact]
    public void CountsByGroupAndByState()
    {
        var snapshots = GitHubClassifier.Snapshots(
            reviewing: [GitHubFixture.Make(number: 1), GitHubFixture.Make(number: 2)],
            authored:
            [
                GitHubFixture.Make(number: 3, checks: GitHubChecks.Failing),
                GitHubFixture.Make(number: 4, decision: GitHubReviewDecision.ChangesRequested),
                GitHubFixture.Make(number: 5),
                GitHubFixture.Make(number: 6, decision: GitHubReviewDecision.Approved),
            ]);
        var counts = new GitHubGroupCounts(snapshots: snapshots);
        Assert.Equal(expected: 2, actual: counts[GitHubPRGroup.ToReview]);
        Assert.Equal(expected: 1, actual: counts[GitHubPRGroup.ChangesRequested]);
        Assert.Equal(expected: 1, actual: counts[GitHubPRGroup.Failing]);
        Assert.Equal(expected: 1, actual: counts[GitHubPRGroup.Ready]);
        Assert.Equal(expected: 1, actual: counts[GitHubPRGroup.Waiting]);
        Assert.Equal(expected: 6, actual: counts.Total);
        Assert.Equal(expected: 3, actual: counts.NeedsYou);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 1, Done: 1), actual: counts.States);
        Assert.Equal(expected: new GitHubGroupCounts(snapshots: snapshots), actual: counts);
        Assert.NotEqual(expected: new GitHubGroupCounts(), actual: counts);
    }

    [Fact]
    public void BriefSentences()
    {
        var sam = Review(reviewer: "sam", state: GitHubReviewState.ChangesRequested);
        static string Sentence(GitHubPullRequest pullRequest, GitHubPRRole role = GitHubPRRole.Author) => Classify(pullRequest: pullRequest, role: role).BriefSentence;
        Assert.Equal(expected: "priya asks for your review on “Pull request 1”.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1), role: GitHubPRRole.Reviewer));
        Assert.Equal(expected: "Your review is requested on “Pull request 1”.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1, author: null), role: GitHubPRRole.Reviewer));
        Assert.Equal(expected: "sam requested changes on “Pull request 1”.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1, decision: GitHubReviewDecision.ChangesRequested, reviews: [sam])));
        Assert.Equal(expected: "Changes are requested on “Pull request 1”.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1, decision: GitHubReviewDecision.ChangesRequested)));
        Assert.Equal(expected: "Checks are failing on “Pull request 1”.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1, checks: GitHubChecks.Failing)));
        Assert.Equal(expected: "“Pull request 1” has merge conflicts.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1, conflicts: true)));
        Assert.Equal(expected: "“Pull request 1” is approved.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1, decision: GitHubReviewDecision.Approved)));
        Assert.Equal(expected: "Checks are running on “Pull request 1”.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1, checks: GitHubChecks.Running)));
        Assert.Equal(expected: "“Pull request 1” is a draft.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1, isDraft: true)));
        Assert.Equal(expected: "“Pull request 1” is waiting for review.", actual: Sentence(pullRequest: GitHubFixture.Make(number: 1)));
    }

    [Fact]
    public void ReadsWhatTheQueryAnswers()
    {
        var pullRequest = GitHubFixture.Decoded(pullRequest: GitHubFixture.PullRequest(
            number: 12, repository: "octo/web", author: "priya", reviewDecision: "CHANGES_REQUESTED", mergeable: "CONFLICTING", rollup: "ERROR",
            reviews: [("CHANGES_REQUESTED", "sam"), ("APPROVED", null), ("DISMISSED", "lee")]));
        Assert.Equal(expected: "PR_octo/web_12", actual: pullRequest.Id);
        Assert.Equal(expected: "octo/web#12", actual: pullRequest.Reference);
        Assert.Equal(expected: "https://github.com/octo/web/pull/12", actual: pullRequest.Url.AbsoluteUri);
        Assert.Equal(expected: "priya", actual: pullRequest.Author);
        Assert.Equal(expected: GitHubReviewDecision.ChangesRequested, actual: pullRequest.ReviewDecision);
        Assert.True(condition: pullRequest.HasConflicts);
        Assert.Equal(expected: GitHubChecks.Failing, actual: pullRequest.Checks);
        Assert.Equal(
            expected: [Review(reviewer: "sam", state: GitHubReviewState.ChangesRequested), new GitHubReview(Reviewer: null, State: GitHubReviewState.Approved)],
            actual: pullRequest.Reviews);
        Assert.Equal(expected: TestTimes.T(seconds: 0), actual: pullRequest.UpdatedAt);
        Assert.Equal(expected: TestTimes.T(seconds: -GitHubFixture.Hour), actual: pullRequest.CreatedAt);
    }

    [Fact]
    public void ReadsChecksAndUnknownValues()
    {
        Assert.Equal(expected: GitHubChecks.Passing, actual: GitHubPullRequest.ChecksOf(rollup: "SUCCESS"));
        Assert.Equal(expected: GitHubChecks.Failing, actual: GitHubPullRequest.ChecksOf(rollup: "FAILURE"));
        Assert.Equal(expected: GitHubChecks.Failing, actual: GitHubPullRequest.ChecksOf(rollup: "ERROR"));
        Assert.Equal(expected: GitHubChecks.Running, actual: GitHubPullRequest.ChecksOf(rollup: "PENDING"));
        Assert.Equal(expected: GitHubChecks.Running, actual: GitHubPullRequest.ChecksOf(rollup: "EXPECTED"));
        Assert.Null(@object: GitHubPullRequest.ChecksOf(rollup: "SOMETHING_NEW"));
        Assert.Null(@object: GitHubPullRequest.ChecksOf(rollup: null));

        var unknown = GitHubFixture.Decoded(pullRequest: GitHubFixture.PullRequest(number: 3, author: null, reviewDecision: "SOMETHING_NEW", mergeable: "UNKNOWN"));
        Assert.Null(@object: unknown.Author);
        Assert.Null(@object: unknown.ReviewDecision);
        Assert.False(condition: unknown.HasConflicts);
        Assert.Null(@object: unknown.Checks);
        Assert.Equal(expected: GitHubPRGroup.Waiting, actual: Classify(pullRequest: unknown).Group);
    }

    [Fact]
    public void ReadsTheBranchEachPullRequestMerges()
    {
        var pullRequest = GitHubFixture.PullRequest(number: 12);
        pullRequest["headRefName"] = "robin/tax-rounding";
        Assert.Equal(expected: "robin/tax-rounding", actual: GitHubFixture.Decoded(pullRequest: pullRequest).Branch);
        // Without one, as in an answer from before, it has none.
        Assert.Null(@object: GitHubFixture.Decoded(pullRequest: GitHubFixture.PullRequest(number: 13)).Branch);
        Assert.Contains(expectedSubstring: " headRefName", actualString: PullRequestQuery.Text, comparisonType: StringComparison.Ordinal);
    }

    /// GitHub's answers, as they are: times in whole seconds, and a commit without checks.
    [Fact]
    public void ReadsATimeInWholeSecondsAndACommitWithoutChecks()
    {
        var pullRequest = GitHubFixture.PullRequest(number: 4);
        pullRequest["updatedAt"] = "2026-10-18T10:00:30Z";
        var read = GitHubFixture.Decoded(pullRequest: pullRequest);
        Assert.Equal(expected: TestTimes.T(seconds: 30), actual: read.UpdatedAt);
        Assert.Null(@object: read.Checks);
    }
}
