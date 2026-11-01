using BriefBar.Core.Demo;
using BriefBar.Core.GitHub;

namespace BriefBar.Core.Tests.GitHub;

/// What one read of GitHub means for the list, why it may be missing or out of date, and the made-up pull requests: the
/// Swift tests' `ReaderTests`, `ProblemTests` and the demo's part of `BranchTests`.
public sealed class ReaderTests
{
    [Fact]
    public void ReadsTheListFromTheAnswer()
    {
        var shared = GitHubFixture.PullRequest(number: 5, repository: "octo/shared", author: GitHubFixture.Me, reviewDecision: "APPROVED");
        var data = GitHubFixture.QueryData(answer: GitHubFixture.Answer(
            reviewing: [GitHubFixture.PullRequest(number: 1, updated: TestTimes.T(seconds: GitHubFixture.Minute)), shared],
            authored: [shared, GitHubFixture.PullRequest(number: 2, author: GitHubFixture.Me, rollup: "FAILURE")]));

        var load = GitHubReader.Load(data: data);
        Assert.Equal(expected: GitHubFixture.Me, actual: load.Login);
        Assert.Equal(expected: ["PR_octo/app_1", "PR_octo/app_2", "PR_octo/shared_5"], actual: load.Items.Select(selector: item => item.Id));
        Assert.Equal(expected: [GitHubPRGroup.ToReview, GitHubPRGroup.Failing, GitHubPRGroup.Ready], actual: load.Items.Select(selector: item => item.Group));
        Assert.Null(@object: load.Notice);
        Assert.False(condition: load.MoreThanShown);
        Assert.Equal(expected: new StateCounts(NeedsYou: 1, Failing: 1, Done: 1), actual: load.Counts.States);
    }

    [Fact]
    public void SaysWhenMoreMatchThanItReads()
    {
        var reviewing = GitHubFixture.QueryData(answer: GitHubFixture.Answer(reviewing: [GitHubFixture.PullRequest(number: 1)], reviewingCount: 51));
        Assert.True(condition: GitHubReader.Load(data: reviewing).MoreThanShown);
        var authored = GitHubFixture.QueryData(answer: GitHubFixture.Answer(authored: [GitHubFixture.PullRequest(number: 1)], authoredCount: 2));
        Assert.True(condition: GitHubReader.Load(data: authored).MoreThanShown);
    }

    [Fact]
    public void SingleSignOnGetsItsOwnNotice()
    {
        GraphQLError[] errors =
        [
            new(Message: "Could not resolve", Type: "NOT_FOUND"),
            new(Message: "Resource protected by organization SAML enforcement. You must grant your OAuth token access.", Type: "FORBIDDEN"),
        ];
        Assert.Equal(
            expected: "Some organizations use single sign-on: authorize the GitHub CLI for them to see their pull requests.",
            actual: GitHubReader.Notice(errors: errors));
    }

    [Fact]
    public void OtherErrorsSayWhatCouldntBeRead()
    {
        Assert.Null(@object: GitHubReader.Notice(errors: []));
        Assert.Equal(expected: "Some pull requests couldn't be read: Something odd", actual: GitHubReader.Notice(errors: [new GraphQLError(Message: "Something odd")]));
        Assert.Equal(
            expected: "Some pull requests couldn't be read: " + new string(c: 'y', count: 200),
            actual: GitHubReader.Notice(errors: [new GraphQLError(Message: new string(c: 'y', count: 400))]));
        // A character made of two isn't cut in half.
        var emoji = string.Concat(values: Enumerable.Repeat(element: "👍", count: 300));
        Assert.Equal(
            expected: "Some pull requests couldn't be read: " + string.Concat(values: Enumerable.Repeat(element: "👍", count: 200)),
            actual: GitHubReader.Notice(errors: [new GraphQLError(Message: emoji)]));
    }

    [Fact]
    public async Task ReadsFromGitHubInOneRequest()
    {
        var server = new GitHubStubServer();
        server.Reply(StubReply.Json(body: GitHubFixture.Answer(
            reviewing: [GitHubFixture.PullRequest(number: 1)],
            authored: [GitHubFixture.PullRequest(number: 2, author: GitHubFixture.Me, reviewDecision: "CHANGES_REQUESTED")],
            errors: [GitHubFixture.Error(message: "SAML enforcement", type: "FORBIDDEN")])));
        using var client = server.Client();

        var load = await GitHubReader.LoadAsync(client: client, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Single(collection: server.Requests);
        Assert.Equal(expected: 1, actual: load.Counts[GitHubPRGroup.ToReview]);
        Assert.Equal(expected: 1, actual: load.Counts[GitHubPRGroup.ChangesRequested]);
        Assert.Contains(expectedSubstring: "single sign-on", actualString: load.Notice, comparisonType: StringComparison.Ordinal);
    }

    [Fact]
    public void TheDemoMatchesWhatItsChecksExpect()
    {
        var now = TestTimes.Reference;
        var load = GitHubDemoData.Load(now: now);
        Assert.Equal(expected: GitHubDemoData.Login, actual: load.Login);
        Assert.All(collection: GitHubPRGroups.All, action: group => Assert.Equal(expected: GitHubDemoData.ExpectedCounts[group], actual: load.Counts[group]));
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 2, Done: 1), actual: load.Counts.States);
        Assert.All(collection: load.Items, action: item => Assert.True(condition: item.Since <= now));
        Assert.Equal(expected: load.Items.Count, actual: load.Items.Select(selector: item => item.Id).Distinct().Count());
        Assert.All(collection: load.Items, action: item => Assert.Equal(expected: "github.com", actual: item.PullRequest.Url.Host));
        // Each has its branch, as on the Mac.
        Assert.All(collection: load.Items, action: item => Assert.False(condition: string.IsNullOrEmpty(value: item.PullRequest.Branch)));
    }

    [Fact]
    public void MapsErrorsToWhatYouCanDo()
    {
        var now = TestTimes.Reference;
        Assert.Equal(expected: GitHubProblem.CliNotFound, actual: GitHubProblem.From(error: GitHubError.FromAuth(error: GitHubAuthError.CliNotFound), now: now));
        Assert.Equal(
            expected: GitHubProblem.SignedOut(detail: "not logged in"),
            actual: GitHubProblem.From(error: GitHubError.FromAuth(error: GitHubAuthError.SignedOut(message: "not logged in")), now: now));
        Assert.Equal(expected: GitHubProblem.AuthFailed(detail: "boom"), actual: GitHubProblem.From(error: GitHubError.FromAuth(error: GitHubAuthError.Failed(message: "boom")), now: now));
        Assert.Equal(expected: GitHubProblem.SignedOut(detail: GitHubError.Unauthorized.Description), actual: GitHubProblem.From(error: GitHubError.Unauthorized, now: now));
        Assert.Equal(expected: GitHubProblem.Offline, actual: GitHubProblem.From(error: GitHubError.Offline, now: now));
        Assert.Equal(
            expected: GitHubProblem.Throttled(until: TestTimes.T(seconds: 120)),
            actual: GitHubProblem.From(error: GitHubError.Throttled(retryAfter: TimeSpan.FromSeconds(value: 120)), now: now));
        Assert.Equal(expected: GitHubProblem.Unreachable(detail: "GitHub answered with HTTP 500."), actual: GitHubProblem.From(error: GitHubError.Http(status: 500), now: now));
        Assert.Equal(expected: GitHubProblem.Unreachable(detail: "GitHub refused the request."), actual: GitHubProblem.From(error: GitHubError.Forbidden, now: now));
        Assert.Equal(
            expected: GitHubProblem.Unreachable(detail: "Unexpected response from GitHub (not JSON)."),
            actual: GitHubProblem.From(error: GitHubError.Decoding(message: "not JSON"), now: now));
    }

    [Fact]
    public void OnlyAMissingSignInNeedsOne()
    {
        Assert.True(condition: GitHubProblem.CliNotFound.NeedsSignIn);
        Assert.True(condition: GitHubProblem.SignedOut(detail: string.Empty).NeedsSignIn);
        GitHubProblem[] others =
        [
            GitHubProblem.AuthFailed(detail: "x"), GitHubProblem.Offline, GitHubProblem.Throttled(until: TestTimes.Reference), GitHubProblem.Unreachable(detail: "x"),
        ];
        Assert.All(collection: others, action: problem => Assert.False(condition: problem.NeedsSignIn));
    }

    [Fact]
    public void MessagesSayWhatsWrong()
    {
        Assert.Contains(expectedSubstring: "isn't installed", actualString: GitHubProblem.CliNotFound.Message, comparisonType: StringComparison.Ordinal);
        Assert.Equal(expected: "Sign in to the GitHub CLI to see your pull requests.", actual: GitHubProblem.SignedOut(detail: "x").Message);
        Assert.Equal(expected: "Couldn't get a token from the GitHub CLI: boom", actual: GitHubProblem.AuthFailed(detail: "boom").Message);
        Assert.Equal(expected: "GitHub refused the request. The list may be out of date.", actual: GitHubProblem.Unreachable(detail: "GitHub refused the request.").Message);
        Assert.StartsWith(
            expectedStartString: "GitHub asked BriefBar to slow down, until ",
            actualString: GitHubProblem.Throttled(until: TestTimes.Reference).Message,
            comparisonType: StringComparison.Ordinal);
        Assert.Equal(expected: "You're offline. The list may be out of date.", actual: GitHubProblem.Offline.Message);
    }
}
