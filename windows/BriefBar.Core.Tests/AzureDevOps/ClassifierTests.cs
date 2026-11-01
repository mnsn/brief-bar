using BriefBar.Core.AzureDevOps;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Ported from the `ClassifierTests` suite in Tests/AzureDevOpsCoreTests/ClassifierTests.swift, but for
/// `theDemoDataCoversEveryGroup`: BriefBar for Windows' demo data is its own, with a test of its own. BriefBar for Windows
/// doesn't announce pull requests yet, so where the Mac's tests ask its `NotificationPlanner`, these check what it goes by.
public sealed class ClassifierTests
{
    /// The first run's three days: nothing before them is new.
    static readonly DateTimeOffset baseline = T(seconds: -3 * Make.Day);

    // Needs you

    [Fact]
    public void AReplyToYourCommentNeedsYou()
    {
        var pr = Make.PR();
        var thread = new ReviewThread(
            Id: 5,
            Comments:
            [
                Make.Comment(id: 1, author: People.Sam, at: T(seconds: -5 * Make.Hour), text: "Why?"),
                Make.Comment(id: 2, author: People.Me, at: T(seconds: -4 * Make.Hour), text: "Because"),
                Make.Comment(id: 3, author: People.Sam, at: T(seconds: -10 * Make.Minute), text: "Makes sense, but cap it"),
            ]);
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), threads: [thread]));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: snapshot.Group);
        Assert.Equal(expected: PRReason.Replied, actual: snapshot.Reason);
        Assert.Equal(expected: "Sam Rivera replied", actual: snapshot.Headline);
        Assert.Equal(expected: "Makes sense, but cap it", actual: snapshot.Detail);
        Assert.Equal(expected: T(seconds: -10 * Make.Minute), actual: snapshot.Since);
        Assert.Equal(expected: pr.ThreadUrl(threadId: 5), actual: snapshot.Url);
        Assert.Equal(expected: ["c5.3"], actual: snapshot.Events.Select(selector: item => item.Id));
    }

    [Fact]
    public void AnsweringItClearsIt()
    {
        var pr = Make.PR();
        var answered = new ReviewThread(
            Id: 5,
            Comments:
            [
                Make.Comment(id: 1, author: People.Sam, at: T(seconds: -Make.Hour), text: "Cap it?"),
                Make.Comment(id: 2, author: People.Me, at: T(seconds: -30 * Make.Minute), text: "Done"),
            ]);
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), threads: [answered]));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Ready, actual: snapshot.Group);
    }

    /// Opening a pull request sees what's there, but a comment that waits on you still needs you: it stays in Needs You,
    /// no longer new, until you reply, its thread is resolved, or you take the pull request off Needs You.
    [Fact]
    public void SeeingItKeepsWhatWaitsOnYou()
    {
        var pr = Make.PR();
        var unanswered = new ReviewThread(Id: 5, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -Make.Hour), text: "Cap it?")]);
        var details = Make.Details(pr: pr, checks: Passing(), threads: [unanswered]);
        var fresh = Classify(pr: pr, details: details);
        Assert.NotNull(@object: fresh);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: fresh.Group);
        Assert.True(condition: fresh.HasNews);
        Assert.Equal(expected: [true], actual: fresh.Events.Select(selector: item => item.IsNew));

        var seen = Classify(pr: pr, details: details, cutoff: T(seconds: -Make.Hour));
        Assert.NotNull(@object: seen);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: seen.Group);
        Assert.False(condition: seen.HasNews);
        Assert.Equal(expected: PRReason.Commented, actual: seen.Reason);
        Assert.Equal(expected: "Sam Rivera commented", actual: seen.Headline);
        Assert.Equal(expected: "Cap it?", actual: seen.Detail);
        Assert.Equal(expected: T(seconds: -Make.Hour), actual: seen.Since);
        Assert.Equal(expected: pr.ThreadUrl(threadId: 5), actual: seen.Url);
        Assert.Equal(expected: ["c5.1"], actual: seen.Events.Select(selector: item => item.Id));
        Assert.Equal(expected: [false], actual: seen.Events.Select(selector: item => item.IsNew));

        // Resolved, it doesn't wait on you anymore.
        var resolved = unanswered with { Status = "fixed" };
        Assert.Equal(
            expected: PRGroup.Ready,
            actual: Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), threads: [resolved]), cutoff: T(seconds: -Make.Hour))?.Group);
        // Nor once you've taken it off Needs You, which sees it too.
        var removed = Classify(pr: pr, details: details, cutoff: T(seconds: -2 * Make.Hour), dismissed: T(seconds: -Make.Hour));
        Assert.NotNull(@object: removed);
        Assert.Equal(expected: PRGroup.Ready, actual: removed.Group);
        Assert.Empty(collection: removed.Events);

        // Until something comes after: that needs you, as new.
        var more = new ReviewThread(Id: 5, Comments: [.. unanswered.Comments, Make.Comment(id: 2, author: People.Sam, at: T(seconds: -Make.Minute), text: "Ping")]);
        var again = Classify(
            pr: pr, details: Make.Details(pr: pr, checks: Passing(), threads: [more]), cutoff: T(seconds: -Make.Hour), dismissed: T(seconds: -Make.Hour));
        Assert.NotNull(@object: again);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: again.Group);
        Assert.True(condition: again.HasNews);
        Assert.Equal(expected: "Sam Rivera commented", actual: again.Headline);
        Assert.Equal(expected: ["c5.2"], actual: again.Events.Select(selector: item => item.Id));
    }

    /// The report that started it: a review you approved goes back to Idle once you've seen it, and so does your draft.
    /// Not while a comment there waits on you.
    [Fact]
    public void ACommentThatWaitsOnYouKeepsAPullRequestOutOfIdle()
    {
        var review = Make.PR(author: People.Sam, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.Approved)]);
        var reply = new ReviewThread(
            Id: 7,
            Comments:
            [
                Make.Comment(id: 1, author: People.Me, at: T(seconds: -Make.Day), text: "Should this retry?"),
                Make.Comment(id: 2, author: People.Sam, at: T(seconds: -Make.Hour), text: "It does, see line 40"),
            ]);
        var details = Make.Details(pr: review, threads: [reply]);
        var seen = Classify(pr: review, role: PRRole.Reviewer, details: details, cutoff: T(seconds: -30 * Make.Minute));
        Assert.NotNull(@object: seen);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: seen.Group);
        Assert.Equal(expected: PRReason.Replied, actual: seen.Reason);
        Assert.Equal(expected: "Sam Rivera replied", actual: seen.Headline);
        Assert.False(condition: seen.HasNews);
        // Once it's resolved, or taken off Needs You, it's idle as before.
        var resolved = reply with { Status = "closed" };
        Assert.Equal(
            expected: PRReason.YouApproved,
            actual: Classify(pr: review, role: PRRole.Reviewer, details: Make.Details(pr: review, threads: [resolved]), cutoff: T(seconds: -30 * Make.Minute))?.Reason);
        Assert.Equal(
            expected: PRReason.YouApproved,
            actual: Classify(pr: review, role: PRRole.Reviewer, details: details, cutoff: T(seconds: -30 * Make.Minute), dismissed: T(seconds: -30 * Make.Minute))?.Reason);

        var draft = Make.PR(draft: true);
        var question = new ReviewThread(Id: 8, Comments: [Make.Comment(id: 1, author: People.Priya, at: T(seconds: -Make.Hour), text: "Is this ready for a look?")]);
        var drafted = Make.Details(pr: draft, threads: [question]);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: Classify(pr: draft, details: drafted, cutoff: T(seconds: -30 * Make.Minute))?.Group);
        Assert.Equal(
            expected: PRReason.Draft,
            actual: Classify(pr: draft, details: drafted, cutoff: T(seconds: -30 * Make.Minute), dismissed: T(seconds: -30 * Make.Minute))?.Reason);
    }

    /// What's new says why it's in Needs You, ahead of what you've seen, and only it is "new".
    [Fact]
    public void WhatsNewComesBeforeWhatYouveSeen()
    {
        var pr = Make.PR();
        ReviewThread[] threads =
        [
            new(Id: 1, Comments: [Make.Comment(id: 1, author: People.Priya, at: T(seconds: -2 * Make.Hour), text: "@Robin Diaz why?", mentions: [People.Me])]),
            new(Id: 2, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -Make.Minute), text: "Nit: typo")]),
        ];
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), threads: threads), cutoff: T(seconds: -Make.Hour));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: snapshot.Group);
        Assert.True(condition: snapshot.HasNews);
        // A mention would come first, but the one here you've seen: what's new names it.
        Assert.Equal(expected: PRReason.Commented, actual: snapshot.Reason);
        Assert.Equal(expected: "Sam Rivera commented", actual: snapshot.Headline);
        Assert.Equal(expected: pr.ThreadUrl(threadId: 2), actual: snapshot.Url);
        Assert.Equal(expected: [true, false], actual: snapshot.Events.Select(selector: item => item.IsNew));

        // Several you've seen aren't "new".
        ReviewThread[] seen =
        [
            new(Id: 1, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -2 * Make.Hour), text: "Nit: typo")]),
            new(Id: 2, Comments: [Make.Comment(id: 1, author: People.Priya, at: T(seconds: -Make.Hour), text: "Add a test?")]),
        ];
        var both = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), threads: seen));
        Assert.NotNull(@object: both);
        Assert.Equal(expected: "2 new comments", actual: both.Headline);
        var bothSeen = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), threads: seen), cutoff: T(seconds: -Make.Hour));
        Assert.NotNull(@object: bothSeen);
        Assert.Equal(expected: "2 comments", actual: bothSeen.Headline);
    }

    /// A comment in a resolved thread is news, but doesn't wait on you once you've seen it.
    [Fact]
    public void AResolvedThreadIsOnlyNews()
    {
        var pr = Make.PR();
        var thread = new ReviewThread(Id: 3, Status: "fixed", Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -Make.Hour), text: "Fixed it for you")]);
        var details = Make.Details(pr: pr, checks: Passing(), threads: [thread]);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: Classify(pr: pr, details: details)?.Group);
        Assert.Equal(expected: PRGroup.Ready, actual: Classify(pr: pr, details: details, cutoff: T(seconds: -Make.Hour))?.Group);
    }

    /// What you've seen waits on you while the pull request is active; once nothing has happened on it for a while, it's
    /// idle. Something new still needs you.
    [Fact]
    public void WhatYouveSeenGoesIdleWithThePullRequest()
    {
        var old = Make.PR(created: T(seconds: -40 * Make.Day));
        var thread = new ReviewThread(Id: 1, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -20 * Make.Day), text: "Still needed?")]);
        var details = Make.Details(pr: old, threads: [thread]);
        var quiet = Classify(pr: old, details: details, cutoff: T(seconds: -19 * Make.Day), dismissed: T(seconds: -30 * Make.Day));
        Assert.NotNull(@object: quiet);
        Assert.Equal(expected: PRGroup.Idle, actual: quiet.Group);
        Assert.Equal(expected: PRReason.Inactive, actual: quiet.Reason);
        Assert.Empty(collection: quiet.Events);
        var never = new ClassifierOptions { InactiveAfter = null };
        Assert.Equal(
            expected: PRGroup.NeedsYou,
            actual: Classify(pr: old, details: details, cutoff: T(seconds: -19 * Make.Day), dismissed: T(seconds: -30 * Make.Day), options: never)?.Group);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: Classify(pr: old, details: details, cutoff: T(seconds: -30 * Make.Day))?.Group);
    }

    /// Seen again after you took it off Needs You: what you took off stays off.
    [Fact]
    public void TakingItOffNeedsYouSeesItToo()
    {
        var pr = Make.PR();
        var thread = new ReviewThread(Id: 5, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -90 * Make.Minute), text: "Cap it?")]);
        var details = Make.Details(pr: pr, checks: Passing(), threads: [thread]);
        // Taken off later than the time it was seen: it counts as seen up to then.
        Assert.Equal(expected: PRGroup.Ready, actual: Classify(pr: pr, details: details, cutoff: T(seconds: -2 * Make.Hour), dismissed: T(seconds: -Make.Hour))?.Group);
    }

    /// The Mac announces what a snapshot marks new that it hadn't announced yet; this checks that what you've seen isn't
    /// marked new.
    [Fact]
    public void WhatYouveSeenIsntAnnounced()
    {
        var pr = Make.PR();
        var thread = new ReviewThread(Id: 5, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -Make.Hour), text: "Cap it?")]);
        var details = Make.Details(pr: pr, checks: Passing(), threads: [thread]);
        var fresh = Classify(pr: pr, details: details);
        Assert.NotNull(@object: fresh);
        var seen = Classify(pr: pr, details: details, cutoff: T(seconds: -Make.Hour));
        Assert.NotNull(@object: seen);
        // New, it's announced: "Sam Rivera commented".
        var comment = Assert.Single(collection: fresh.Events);
        Assert.True(condition: comment.IsNew);
        Assert.Equal(expected: (PREventKind.Comment, "Sam Rivera"), actual: (comment.Kind, comment.Actor));
        // Not when it's first listed already seen, nor when you've just seen it: it's the same comment, no longer new.
        Assert.Equal(expected: [comment with { IsNew = false }], actual: seen.Events);
    }

    [Fact]
    public void NewCommentsOnYourPullRequestNeedYou()
    {
        var pr = Make.PR();
        ReviewThread[] threads =
        [
            new(Id: 1, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -2 * Make.Hour), text: "Nit: typo")]),
            new(Id: 2, Comments: [Make.Comment(id: 1, author: People.Priya, at: T(seconds: -Make.Hour), text: "Add a test?")]),
            new(Id: 3, Comments: [Make.Comment(id: 1, author: People.Bot, at: T(seconds: -Make.Minute), text: "2 tests failed")]),
        ];
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), threads: threads));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRReason.Commented, actual: snapshot.Reason);
        Assert.Equal(expected: "2 new comments", actual: snapshot.Headline);
        Assert.Equal(expected: "Add a test?", actual: snapshot.Detail);
        // The bot's comment isn't counted.
        Assert.Equal(expected: 2, actual: snapshot.Events.Count);
        Assert.Equal(expected: T(seconds: -Make.Hour), actual: snapshot.Since);
    }

    [Fact]
    public void MentionsComeFirst()
    {
        var pr = Make.PR(author: People.Sam);
        ReviewThread[] threads =
        [
            new(
                Id: 1,
                Comments:
                [
                    Make.Comment(id: 1, author: People.Me, at: T(seconds: -3 * Make.Hour), text: "Question"),
                    Make.Comment(id: 2, author: People.Sam, at: T(seconds: -Make.Minute), text: "Answer"),
                ]),
            new(Id: 2, Comments: [Make.Comment(id: 1, author: People.Priya, at: T(seconds: -Make.Hour), text: "@Robin Diaz thoughts?", mentions: [People.Me])]),
            // Comments between others don't concern you as a reviewer.
            new(Id: 3, Comments: [Make.Comment(id: 1, author: People.Priya, at: T(seconds: -Make.Minute), text: "Hmm")]),
        ];
        var snapshot = Classify(pr: pr, role: PRRole.Reviewer, details: Make.Details(pr: pr, threads: threads));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRReason.Mentioned, actual: snapshot.Reason);
        Assert.Equal(expected: "Priya Shah mentioned you", actual: snapshot.Headline);
        Assert.Equal(expected: pr.ThreadUrl(threadId: 2), actual: snapshot.Url);
        Assert.Equal(expected: [PREventKind.Mention, PREventKind.Reply], actual: snapshot.Events.Select(selector: item => item.Kind).Distinct().Order());
    }

    [Fact]
    public void ReviewRequests()
    {
        var pr = Make.PR(author: People.Sam, created: T(seconds: -2 * Make.Day), reviewers: [new Reviewer(Person: People.Me, Vote: Vote.None, IsRequired: true)]);
        var added = new Activity(threadId: 9, kind: ActivityKind.ReviewersChanged, at: T(seconds: -Make.Hour), actor: People.Sam, added: [People.Me.Id]);
        var fresh = Classify(pr: pr, role: PRRole.Reviewer, details: Make.Details(pr: pr, activity: [added]));
        Assert.NotNull(@object: fresh);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: fresh.Group);
        Assert.Equal(expected: PRReason.ReviewRequested, actual: fresh.Reason);
        Assert.Equal(expected: "Required reviewer", actual: fresh.Detail);
        Assert.Equal(expected: T(seconds: -Make.Hour), actual: fresh.Since);

        // Once seen, it waits in To Review.
        var seen = Classify(pr: pr, role: PRRole.Reviewer, details: Make.Details(pr: pr, activity: [added]), cutoff: T(seconds: 0));
        Assert.NotNull(@object: seen);
        Assert.Equal(expected: PRGroup.ToReview, actual: seen.Group);
        Assert.Equal(expected: "Required review", actual: seen.Headline);
        Assert.Equal(expected: "By Sam Rivera", actual: seen.Detail);

        // Without a record of when you were added, the creation date counts: older than the cutoff here.
        var old = Make.PR(author: People.Sam, created: T(seconds: -5 * Make.Day), reviewers: [new Reviewer(Person: People.Me, Vote: Vote.None)]);
        Assert.Equal(expected: PRGroup.ToReview, actual: Classify(pr: old, role: PRRole.Reviewer, details: Make.Details(pr: old, lastActivity: T(seconds: -Make.Day)))?.Group);

        // A draft becoming ready for review asks again.
        var published = new Activity(threadId: 10, kind: ActivityKind.DraftChanged, at: T(seconds: -2 * Make.Hour), actor: People.Sam);
        Assert.Equal(expected: PRReason.ReviewRequested, actual: Classify(pr: old, role: PRRole.Reviewer, details: Make.Details(pr: old, activity: [published]))?.Reason);
    }

    [Fact]
    public void NewCommitsSinceYourVote()
    {
        var pr = Make.PR(author: People.Sam, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.WaitingForAuthor)]);
        var voted = new Activity(threadId: 1, kind: ActivityKind.Vote, at: T(seconds: -Make.Day), actor: People.Me, vote: Vote.WaitingForAuthor);
        Activity[] pushes =
        [
            new(threadId: 2, kind: ActivityKind.Push, at: T(seconds: -2 * Make.Hour), actor: People.Sam, commitCount: 2),
            new(threadId: 3, kind: ActivityKind.Push, at: T(seconds: -Make.Hour), actor: People.Sam, commitCount: 1),
        ];
        var snapshot = Classify(pr: pr, role: PRRole.Reviewer, details: Make.Details(pr: pr, activity: [voted, .. pushes]));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRReason.NewCommits, actual: snapshot.Reason);
        Assert.Equal(expected: "3 new commits since your vote", actual: snapshot.Headline);
        Assert.Equal(expected: ["p3"], actual: snapshot.Events.Select(selector: item => item.Id));

        // Seen since your vote, with nothing new: it waits for the author.
        var quiet = Classify(pr: pr, role: PRRole.Reviewer, details: Make.Details(pr: pr, activity: [voted]), cutoff: T(seconds: -Make.Day));
        Assert.NotNull(@object: quiet);
        Assert.Equal(expected: PRGroup.Waiting, actual: quiet.Group);
        Assert.Equal(expected: PRReason.WaitingForAuthor, actual: quiet.Reason);
        Assert.Equal(expected: "You asked Sam Rivera for changes", actual: quiet.Detail);
    }

    [Fact]
    public void VotesThatWantChanges()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.WaitingForAuthor), new Reviewer(Person: People.Priya, Vote: Vote.Rejected)]);
        Activity[] votes =
        [
            new(threadId: 1, kind: ActivityKind.Vote, at: T(seconds: -2 * Make.Hour), actor: People.Sam, vote: Vote.WaitingForAuthor),
            new(threadId: 2, kind: ActivityKind.Vote, at: T(seconds: -Make.Hour), actor: People.Priya, vote: Vote.Rejected),
        ];
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), activity: votes));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: snapshot.Group);
        Assert.Equal(expected: PRReason.Rejected, actual: snapshot.Reason);
        Assert.Equal(expected: "Priya Shah rejected it", actual: snapshot.Headline);
        Assert.Equal(expected: 2, actual: snapshot.PendingEvents.Count());

        // Once you've pushed changes, it's their turn: it's answered until you've seen that, then it waits.
        Activity[] pushed = [.. votes, new(threadId: 3, kind: ActivityKind.Push, at: T(seconds: -Make.Minute), actor: People.Me, commitCount: 1)];
        var answered = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), activity: pushed));
        Assert.NotNull(@object: answered);
        Assert.Equal(expected: PRGroup.Answered, actual: answered.Group);
        Assert.Equal(expected: "You pushed 1 commit", actual: answered.Headline);
        Assert.Equal(expected: "Priya Shah rejected it", actual: answered.Detail);
        var after = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), activity: pushed), cutoff: T(seconds: -Make.Minute));
        Assert.NotNull(@object: after);
        Assert.Equal(expected: PRGroup.Waiting, actual: after.Group);
        Assert.Equal(expected: PRReason.Rejected, actual: after.Reason);
        Assert.Equal(expected: "Sam Rivera, Priya Shah", actual: after.Detail);

        // A vote that has since changed isn't news.
        var changed = pr with { Reviewers = [new Reviewer(Person: People.Sam, Vote: Vote.Approved), new Reviewer(Person: People.Priya, Vote: Vote.Approved)] };
        var old = Classify(pr: changed, details: Make.Details(pr: changed, checks: Passing(), activity: votes));
        Assert.NotNull(@object: old);
        Assert.Equal(expected: PRGroup.Ready, actual: old.Group);
        Assert.Empty(collection: old.Events);
    }

    [Fact]
    public void VotesFromRemovedReviewersDontCount()
    {
        // Sam asked for changes and Priya approved, and then both were removed from the pull request.
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Alex, Vote: Vote.None)]);
        Activity[] votes =
        [
            new(threadId: 1, kind: ActivityKind.Vote, at: T(seconds: -2 * Make.Hour), actor: People.Sam, vote: Vote.WaitingForAuthor),
            new(threadId: 2, kind: ActivityKind.Vote, at: T(seconds: -Make.Hour), actor: People.Priya, vote: Vote.Approved),
        ];
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), activity: votes));
        Assert.NotNull(@object: snapshot);
        Assert.NotEqual(expected: PRGroup.NeedsYou, actual: snapshot.Group);
        Assert.Empty(collection: snapshot.Events);
    }

    [Fact]
    public void ApprovalsAreNewsButDontNeedYou()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved)]);
        var approval = new Activity(threadId: 4, kind: ActivityKind.Vote, at: T(seconds: -Make.Hour), actor: People.Sam, vote: Vote.Approved);
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(), activity: [approval]));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Ready, actual: snapshot.Group);
        Assert.Equal(expected: [PREventKind.Approved], actual: snapshot.Events.Select(selector: item => item.Kind));
        Assert.Empty(collection: snapshot.PendingEvents);
        Assert.Equal(expected: ["Sam Rivera"], actual: snapshot.Approvals);
    }

    // Failing, ready and waiting

    [Fact]
    public void Failures()
    {
        var pr = Make.PR();
        (PRGroup Group, PRReason Reason, string Headline, string? Detail) State(IEnumerable<Check> checks, string merge = "succeeded")
        {
            var copy = pr with { MergeStatus = merge };
            var snapshot = Classify(pr: copy, details: Make.Details(pr: copy, checks: checks, lastActivity: T(seconds: -Make.Hour)));
            Assert.NotNull(@object: snapshot);
            return (snapshot.Group, snapshot.Reason, snapshot.Headline, snapshot.Detail);
        }
        var failedBuild = new Check(Name: "web-ci", Kind: CheckKind.Build, State: CheckState.Failed, CompletedAt: T(seconds: -Make.Hour));
        Assert.Equal(expected: (PRGroup.Failing, PRReason.BuildFailed, "Build failed", "web-ci"), actual: State(checks: [failedBuild]));
        Assert.Equal(expected: (PRGroup.Failing, PRReason.BuildFailed, "Build failed", "web-ci · merge conflicts"), actual: State(checks: [failedBuild], merge: "conflicts"));
        Assert.Equal(expected: "2 builds failed", actual: State(checks: [failedBuild, new Check(Name: "api-ci", Kind: CheckKind.Build, State: CheckState.Failed)]).Headline);
        Assert.Equal(
            expected: (PRGroup.Failing, PRReason.CheckFailed, "Check failed", "scan"),
            actual: State(checks: [new Check(Name: "scan", Kind: CheckKind.Status, State: CheckState.Failed)]));
        Assert.Equal(expected: (PRGroup.Failing, PRReason.Conflicts, "Merge conflicts", "fix-total into main"), actual: State(checks: [], merge: "conflicts"));
        Assert.Equal(
            expected: (PRGroup.Failing, PRReason.MergeFailed, "Merge failed", "Azure DevOps couldn't merge fix-total into main"),
            actual: State(checks: [], merge: "failure"));
        Assert.Equal(
            expected: (PRGroup.Failing, PRReason.BuildExpired, "Build expired", "web-ci · queue it again"),
            actual: State(checks: [new Check(Name: "web-ci", Kind: CheckKind.Build, State: CheckState.Expired)]));
        // An optional build doesn't count.
        var optional = new Check(Name: "perf", Kind: CheckKind.Build, State: CheckState.Failed, IsBlocking: false);
        Assert.Equal(expected: PRGroup.Ready, actual: State(checks: Passing(extra: [optional])).Group);
    }

    /// A merge Azure DevOps couldn't make, for something other than conflicts, holds it up as conflicts do, however its
    /// policies stand.
    [Fact]
    public void AMergeAzureDevOpsCouldntMakeIsFailing()
    {
        Reviewer[] approved = [new Reviewer(Person: People.Sam, Vote: Vote.Approved)];
        PRSnapshot Row(string merge, IEnumerable<Check> checks)
        {
            var pr = Make.PR(reviewers: approved, merge: merge);
            var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: checks, lastActivity: T(seconds: -Make.Hour)));
            Assert.NotNull(@object: snapshot);
            return snapshot;
        }
        (string Merge, string Headline, string Detail)[] cases =
        [
            ("failure", "Merge failed", "Azure DevOps couldn't merge fix-total into main"),
            ("rejectedByPolicy", "Merge rejected", "A policy rejected merging fix-total into main"),
        ];
        foreach (var (merge, headline, detail) in cases)
        {
            var failed = Row(merge: merge, checks: Passing());
            Assert.Equal(expected: (PRGroup.Failing, PRReason.MergeFailed, headline, detail), actual: (failed.Group, failed.Reason, failed.Headline, failed.Detail));
            Assert.Equal(expected: "“Fix the checkout total” can't be merged.", actual: Brief.Item(snapshot: failed).Sentence);
        }
        // After a failed build or check, its merge is said too, as conflicts are.
        Assert.Equal(
            expected: "web-ci · merge failed",
            actual: Row(merge: "failure", checks: [new Check(Name: "web-ci", Kind: CheckKind.Build, State: CheckState.Failed)]).Detail);
        Assert.Equal(
            expected: "scan · merge rejected",
            actual: Row(merge: "rejectedByPolicy", checks: [new Check(Name: "scan", Kind: CheckKind.Status, State: CheckState.Failed)]).Detail);
        // Merges still being checked, or never checked, aren't failures.
        Assert.All(collection: ["queued", "notSet"], action: merge => Assert.Equal(expected: PRGroup.Ready, actual: Row(merge: merge, checks: Passing()).Group));
    }

    /// A person it requires as a reviewer, whether a policy or someone added them, keeps it out of Ready to complete until
    /// they approve, even one who declined: Azure DevOps won't complete it before. A team counts as its policy says.
    [Fact]
    public void ARequiredReviewerWhoHasntApprovedHoldsItUp()
    {
        var priya = new Reviewer(Person: People.Priya, Vote: Vote.Approved);
        PRSnapshot Row(IEnumerable<Reviewer> reviewers, IEnumerable<Check>? checks = null)
        {
            var pr = Make.PR(reviewers: reviewers);
            var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: checks ?? Passing(), lastActivity: T(seconds: -Make.Hour)));
            Assert.NotNull(@object: snapshot);
            return snapshot;
        }

        var waiting = Row(reviewers: [priya, new Reviewer(Person: People.Sam, Vote: Vote.None, IsRequired: true)]);
        Assert.Equal(
            expected: (PRGroup.Waiting, PRReason.WaitingForReviewers, "Waiting for reviewers", "Approved by Priya Shah · Sam Rivera is required"),
            actual: (waiting.Group, waiting.Reason, waiting.Headline, waiting.Detail));

        // Two, and one who declined.
        Assert.Equal(
            expected: "Approved by Priya Shah · Sam Rivera and Alex Kim are required",
            actual: Row(reviewers: [
                priya,
                new Reviewer(Person: People.Sam, Vote: Vote.None, IsRequired: true),
                new Reviewer(Person: People.Alex, Vote: Vote.None, IsRequired: true, HasDeclined: true),
            ]).Detail);

        // More than three, the first three and how many more.
        var jordan = new Person(id: "66666666-6666-6666-6666-666666666666", name: "Jordan Lee");
        var casey = new Person(id: "77777777-7777-7777-7777-777777777777", name: "Casey Park");
        Assert.Equal(
            expected: "Approved by Priya Shah · Sam Rivera, Alex Kim, Jordan Lee, and 1 more are required",
            actual: Row(reviewers: [
                priya,
                new Reviewer(Person: People.Sam, Vote: Vote.None, IsRequired: true),
                new Reviewer(Person: People.Alex, Vote: Vote.None, IsRequired: true),
                new Reviewer(Person: jordan, Vote: Vote.None, IsRequired: true),
                new Reviewer(Person: casey, Vote: Vote.None, IsRequired: true),
            ]).Detail);

        // Once they approved, it's ready.
        Assert.Equal(expected: PRGroup.Ready, actual: Row(reviewers: [priya, new Reviewer(Person: People.Sam, Vote: Vote.ApprovedWithSuggestions, IsRequired: true)]).Group);

        // A team counts as its policy says.
        var team = new Reviewer(Person: new Person(id: "team", name: "Team"), Vote: Vote.None, IsRequired: true, IsGroup: true);
        Assert.Equal(
            expected: PRGroup.Ready,
            actual: Row(reviewers: [priya, team], checks: Passing(extra: [new Check(Name: "Required reviewers", Kind: CheckKind.Reviewers, State: CheckState.Passed)])).Group);

        // Before its policies are read again after a vote or a push, it says the approvals, as before.
        var pr = Make.PR(reviewers: [priya, new Reviewer(Person: People.Sam, Vote: Vote.None, IsRequired: true)]);
        var outdated = Classify(pr: pr with { SourceCommit = "abd" }, details: Make.Details(pr: pr, checks: Passing(), lastActivity: T(seconds: -Make.Hour)));
        Assert.Equal(expected: (PRGroup.Waiting, "Approved by Priya Shah"), actual: (outdated?.Group, outdated?.Detail));
    }

    [Fact]
    public void AFailedBuildSaysWhereItFailedOnceThatsKnown()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved)]);
        var failure = new PipelineFailure(Stage: "Test", Step: "Run unit tests", Message: "2 tests failed in CheckoutTests.");
        var failed = new Check(Name: "web-ci", Kind: CheckKind.Build, State: CheckState.Failed, CompletedAt: T(seconds: -Make.Hour), BuildId: 41, Failure: failure);
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: [failed], lastActivity: T(seconds: -Make.Hour)));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: "Build failed", actual: snapshot.Headline);
        Assert.Equal(expected: "web-ci · Run unit tests: 2 tests failed in CheckoutTests.", actual: snapshot.Detail);
        Assert.Equal(expected: failure, actual: snapshot.Failure);

        // Without an error, the step; another failed build or check is named as before.
        var quiet = new Check(
            Name: "web-ci", Kind: CheckKind.Build, State: CheckState.Failed, BuildId: 41, Failure: new PipelineFailure(Stage: null, Step: "Build", Message: null));
        var both = Classify(
            pr: pr,
            details: Make.Details(
                pr: pr,
                checks: [quiet, new Check(Name: "api-ci", Kind: CheckKind.Build, State: CheckState.Failed), new Check(Name: "scan", Kind: CheckKind.Status, State: CheckState.Failed)],
                lastActivity: T(seconds: -Make.Hour)));
        Assert.NotNull(@object: both);
        Assert.Equal(expected: "web-ci · Build failed, api-ci, scan", actual: both.Detail);
        Assert.Equal(expected: "Build", actual: both.Failure?.Step);

        // A failing check that isn't a build says nothing about where.
        var check = Classify(
            pr: pr, details: Make.Details(pr: pr, checks: [new Check(Name: "scan", Kind: CheckKind.Status, State: CheckState.Failed)], lastActivity: T(seconds: -Make.Hour)));
        Assert.NotNull(@object: check);
        Assert.Null(@object: check.Failure);

        var brief = Brief.Item(snapshot: snapshot);
        Assert.Equal(expected: "“Fix the checkout total” failed at Run unit tests.", actual: brief.Sentence);
    }

    [Fact]
    public void ReadyToComplete()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved), new Reviewer(Person: People.Priya, Vote: Vote.ApprovedWithSuggestions)]);
        var mergeStrategy = new Check(Name: "Require a merge strategy", Kind: CheckKind.Completion, State: CheckState.Pending);
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: Passing(extra: [mergeStrategy]), lastActivity: T(seconds: -Make.Hour)));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Ready, actual: snapshot.Group);
        Assert.Equal(expected: PRReason.ReadyToComplete, actual: snapshot.Reason);
        Assert.Equal(expected: "Approved by Sam Rivera, Priya Shah", actual: snapshot.Detail);
        Assert.Equal(expected: CheckState.Passed, actual: snapshot.CheckState);

        var auto = pr with { AutoComplete = true };
        Assert.Equal(expected: "Completing automatically", actual: Classify(pr: auto, details: Make.Details(pr: auto, checks: Passing(), lastActivity: T(seconds: -Make.Hour)))?.Headline);

        // Without any reviewer policy, an approval is what makes it ready.
        var noPolicy = Make.PR();
        Check[] build = [new(Name: "CI", Kind: CheckKind.Build, State: CheckState.Passed)];
        Assert.Equal(expected: PRGroup.Waiting, actual: Classify(pr: noPolicy, details: Make.Details(pr: noPolicy, checks: build, lastActivity: T(seconds: -Make.Hour)))?.Group);
        var approved = noPolicy with { Reviewers = [new Reviewer(Person: People.Sam, Vote: Vote.Approved)] };
        Assert.Equal(expected: PRGroup.Ready, actual: Classify(pr: approved, details: Make.Details(pr: approved, checks: build, lastActivity: T(seconds: -Make.Hour)))?.Group);
    }

    [Fact]
    public void ReadyOnlyWithCurrentReadablePolicies()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved)]);
        var details = Make.Details(pr: pr, checks: Passing(), lastActivity: T(seconds: -Make.Hour));
        var ready = Classify(pr: pr, details: details);
        Assert.NotNull(@object: ready);
        Assert.Equal(expected: PRGroup.Ready, actual: ready.Group);

        // A push since the details were read: their passing checks may not apply any more.
        var pushed = pr with { SourceCommit = "abd" };
        var outdated = Classify(pr: pushed, details: details);
        Assert.NotNull(@object: outdated);
        Assert.Equal(expected: PRGroup.Waiting, actual: outdated.Group);
        Assert.Equal(expected: "Waiting for reviewers", actual: outdated.Headline);
        // And it isn't announced as ready: the Mac announces your pull request moving to Ready, and this one stays where it
        // was while its build ran, with nothing new.
        var before = Classify(pr: pushed, details: Make.Details(pr: pushed, checks: [new Check(Name: "CI", Kind: CheckKind.Build, State: CheckState.Running)]));
        Assert.NotNull(@object: before);
        Assert.Equal(expected: before.Group, actual: outdated.Group);
        Assert.DoesNotContain(collection: outdated.Events, filter: item => item.IsNew);

        // A project whose policies you can't read: nobody can tell it's ready.
        var unreadable = Classify(pr: pr, details: Make.Details(pr: pr, checksKnown: false, lastActivity: T(seconds: -Make.Hour)));
        Assert.NotNull(@object: unreadable);
        Assert.Equal(expected: PRGroup.Waiting, actual: unreadable.Group);
        Assert.Equal(expected: "Can't read its policies", actual: unreadable.Headline);
        Assert.Equal(expected: "Approved by Sam Rivera", actual: unreadable.Detail);
    }

    [Fact]
    public void Waiting()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved)]);
        (PRReason Reason, string Headline, string? Detail) Describe(IEnumerable<Check> checks)
        {
            var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, checks: checks, lastActivity: T(seconds: -Make.Hour)));
            Assert.NotNull(@object: snapshot);
            Assert.Equal(expected: PRGroup.Waiting, actual: snapshot.Group);
            return (snapshot.Reason, snapshot.Headline, snapshot.Detail);
        }
        var reviewers = new Check(Name: "Minimum number of reviewers", Kind: CheckKind.Reviewers, State: CheckState.Pending, MinimumApprovers: 2);
        var running = new Check(Name: "web-ci", Kind: CheckKind.Build, State: CheckState.Running);
        Assert.Equal(
            expected: (PRReason.WaitingForReviewers, "Waiting for reviewers", "1 of 2 approvals · build running"),
            actual: Describe(checks: [reviewers, running]));
        Assert.Equal(expected: PRReason.ChecksRunning, actual: Describe(checks: [running]).Reason);
        Assert.Equal(expected: "Build running", actual: Describe(checks: [running]).Headline);
        Assert.Equal(expected: "Checks running", actual: Describe(checks: [new Check(Name: "license", Kind: CheckKind.Status, State: CheckState.Pending)]).Headline);
        Assert.Equal(
            expected: (PRReason.RequirementsPending, "Build hasn't run", "web-ci · queue it"),
            actual: Describe(checks: [new Check(Name: "web-ci", Kind: CheckKind.Build, State: CheckState.NotRun)]));
        Assert.Equal(
            expected: "Link a work item",
            actual: Describe(checks: [new Check(Name: "Work item linking", Kind: CheckKind.Requirement, State: CheckState.Pending)]).Headline);
        Assert.Equal(
            expected: "Resolve comments",
            actual: Describe(checks: [new Check(Name: "Comment requirements", Kind: CheckKind.Requirement, State: CheckState.Pending)]).Headline);
        Assert.Equal(
            expected: "Approved by Sam Rivera",
            actual: Describe(checks: [new Check(Name: "Proof Of Presence", Kind: CheckKind.Reviewers, State: CheckState.Pending)]).Detail);
    }

    [Fact]
    public void WithoutDetailsItWaits()
    {
        var snapshot = Classify(pr: Make.PR());
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Waiting, actual: snapshot.Group);
        Assert.False(condition: snapshot.HasDetails);
        Assert.Null(value: snapshot.CheckState);
        // Merge conflicts are in the list itself.
        Assert.Equal(expected: PRGroup.Failing, actual: Classify(pr: Make.PR(merge: "conflicts"))?.Group);
    }

    // Done and idle

    [Fact]
    public void CompletedPullRequestsStayInDoneForADay()
    {
        var completed = Make.PR(status: PullRequestStatus.Completed, closed: T(seconds: -2 * Make.Hour));
        var snapshot = Classify(pr: completed);
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Done, actual: snapshot.Group);
        Assert.Equal(expected: PRReason.Completed, actual: snapshot.Reason);
        Assert.Equal(expected: "Merged into main", actual: snapshot.Detail);
        Assert.Equal(expected: T(seconds: -2 * Make.Hour), actual: snapshot.Since);
        Assert.NotNull(@object: Classify(pr: completed, now: T(seconds: 22 * Make.Hour)));
        Assert.Null(@object: Classify(pr: completed, now: T(seconds: 22 * Make.Hour + 1)));
        // Cleared or opened since.
        Assert.Null(@object: Classify(pr: completed, cutoff: T(seconds: -Make.Hour)));
        Assert.Equal(expected: PRReason.Abandoned, actual: Classify(pr: Make.PR(status: PullRequestStatus.Abandoned, closed: T(seconds: -Make.Hour)))?.Reason);
    }

    [Fact]
    public void Idle()
    {
        var draft = Make.PR(draft: true);
        Assert.Equal(expected: PRReason.Draft, actual: Classify(pr: draft, details: Make.Details(pr: draft))?.Reason);

        var old = Make.PR(created: T(seconds: -40 * Make.Day));
        var stale = Make.Details(pr: old, checks: [new Check(Name: "CI", Kind: CheckKind.Build, State: CheckState.Failed)], lastActivity: T(seconds: -20 * Make.Day));
        var snapshot = Classify(pr: old, details: stale);
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Idle, actual: snapshot.Group);
        Assert.Equal(expected: "No activity for 20 days", actual: snapshot.Headline);
        Assert.Equal(expected: PRGroup.Failing, actual: Classify(pr: old, details: stale, options: new ClassifierOptions { InactiveAfter = null })?.Group);

        // New activity on an old pull request still needs you.
        var reply = new ReviewThread(Id: 1, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -Make.Hour), text: "Ping")]);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: Classify(pr: old, details: Make.Details(pr: old, threads: [reply]))?.Group);

        var approvedByMe = Make.PR(
            author: People.Sam, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.Approved), new Reviewer(Person: People.Priya, Vote: Vote.Approved)]);
        var approved = Classify(pr: approvedByMe, role: PRRole.Reviewer, details: Make.Details(pr: approvedByMe, lastActivity: T(seconds: -Make.Hour)));
        Assert.NotNull(@object: approved);
        Assert.Equal(expected: PRGroup.Idle, actual: approved.Group);
        Assert.Equal(expected: PRReason.YouApproved, actual: approved.Reason);
        Assert.Equal(expected: "Also approved by Priya Shah", actual: approved.Detail);

        var declined = Make.PR(author: People.Sam, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.None, HasDeclined: true)]);
        Assert.Equal(
            expected: PRReason.Declined,
            actual: Classify(pr: declined, role: PRRole.Reviewer, details: Make.Details(pr: declined, lastActivity: T(seconds: -Make.Hour)))?.Reason);
    }

    // Ordering and counts

    [Fact]
    public void OrdersByGroupThenMostRecent()
    {
        static PRSnapshot Item(int number, PRGroup group, DateTimeOffset? since)
        {
            var snapshot = Classify(pr: Make.PR(number: number));
            Assert.NotNull(@object: snapshot);
            return snapshot with { Group = group, Since = since };
        }
        PRSnapshot[] items =
        [
            Item(number: 1, group: PRGroup.Idle, since: T(seconds: -1)),
            Item(number: 2, group: PRGroup.Waiting, since: T(seconds: -50)),
            Item(number: 3, group: PRGroup.NeedsYou, since: T(seconds: -30)),
            Item(number: 4, group: PRGroup.NeedsYou, since: T(seconds: -10)),
            Item(number: 5, group: PRGroup.Failing, since: T(seconds: -5)),
            Item(number: 6, group: PRGroup.Waiting, since: T(seconds: -5)),
            Item(number: 7, group: PRGroup.Done, since: null),
            Item(number: 8, group: PRGroup.Ready, since: T(seconds: -1)),
            Item(number: 9, group: PRGroup.ToReview, since: T(seconds: 0)),
            Item(number: 10, group: PRGroup.Answered, since: T(seconds: -100)),
        ];
        var shuffled = items.OrderBy(keySelector: _ => Random.Shared.Next()).ToList();
        Assert.Equal(expected: [4, 3, 10, 5, 8, 9, 6, 2, 7, 1], actual: PROrdering.Sorted(snapshots: shuffled).Select(selector: snapshot => snapshot.Key.Number));
        var counts = new GroupCounts(snapshots: items);
        Assert.Equal(expected: [2, 1, 1, 1, 1, 2, 1, 1], actual: PRGroups.All.Select(selector: group => counts[group]));
        Assert.Equal(expected: 9, actual: counts.Active);
    }

    [Fact]
    public void CountsOnlyWhatTheMenuBarShowsByState()
    {
        // Needs You, Failing and Ready to Complete are ✋, ✕ and ✓ for every source. Answered, waiting, done and
        // idle pull requests are in no state, and To Review is only while you show it in the menu bar.
        ItemState?[] withoutToReview = [ItemState.NeedsYou, null, ItemState.Failing, ItemState.Done, null, null, null, null];
        ItemState?[] withToReview = [ItemState.NeedsYou, null, ItemState.Failing, ItemState.Done, ItemState.NeedsYou, null, null, null];
        Assert.Equal(expected: withoutToReview, actual: PRGroups.All.Select(selector: group => group.State(showToReview: false)));
        Assert.Equal(expected: withToReview, actual: PRGroups.All.Select(selector: group => group.State(showToReview: true)));

        // A power of two in each group, so that each state's count says which groups it adds up.
        var snapshot = Classify(pr: Make.PR());
        Assert.NotNull(@object: snapshot);
        var counts = new GroupCounts(
            snapshots: PRGroups.All.SelectMany(selector: (group, offset) => Enumerable.Repeat(element: snapshot with { Group = group }, count: 1 << offset)));
        Assert.Equal(expected: new StateCounts(NeedsYou: 1, Failing: 4, Done: 8), actual: counts.States(showToReview: false));
        Assert.Equal(expected: new StateCounts(NeedsYou: 1 + 16, Failing: 4, Done: 8), actual: counts.States(showToReview: true));
    }

    /// Seen up to `cutoff`; taken off Needs You up to `dismissed`, or else nothing since the earlier of `cutoff` and the
    /// first run's three days.
    static PRSnapshot? Classify(
        PullRequest pr,
        PRRole role = PRRole.Author,
        PRDetails? details = null,
        DateTimeOffset? cutoff = null,
        DateTimeOffset? dismissed = null,
        DateTimeOffset? now = null,
        ClassifierOptions? options = null)
    {
        var seenCutoff = cutoff ?? baseline;
        return PRClassifier.Snapshot(
            record: new PRRecord(pullRequest: pr, role: role, me: People.Me.Id, details: details),
            seenCutoff: seenCutoff,
            dismissedCutoff: dismissed ?? (seenCutoff < baseline ? seenCutoff : baseline),
            now: now ?? T(seconds: 0),
            options: options ?? new ClassifierOptions());
    }

    /// A build and a reviewer policy that pass, then `extra`.
    static List<Check> Passing(IEnumerable<Check>? extra = null) =>
    [
        new Check(Name: "CI", Kind: CheckKind.Build, State: CheckState.Passed),
        new Check(Name: "Minimum number of reviewers", Kind: CheckKind.Reviewers, State: CheckState.Passed),
        .. extra ?? [],
    ];
}
