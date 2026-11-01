using BriefBar.Core.AzureDevOps;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Ported from Tests/AzureDevOpsCoreTests/AnsweredTests.swift. What needed you and you've answered yourself in Azure DevOps
/// stays in view, in Answered, until you've seen it in the panel or for a day.
public sealed class AnsweredTests
{
    /// The app the pull requests are sent in: Teams.
    const string Teams = "com.microsoft.teams2";

    /// The first run's three days: nothing before them is new.
    static readonly DateTimeOffset baseline = T(seconds: -3 * Make.Day);

    [Fact]
    public void ApprovingAPullRequestSentToYouKeepsItInView()
    {
        // Like a review assigned to your team: your vote adds you as a reviewer yourself.
        var pr = Make.PR(author: People.Alex, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.Approved)]);
        var details = Make.Details(
            pr: pr,
            activity:
            [
                Added(thread: 1, reviewer: People.Me, by: People.Me, at: T(seconds: -5 * Make.Minute)),
                Voted(thread: 2, voter: People.Me, vote: Vote.Approved, at: T(seconds: -5 * Make.Minute)),
            ]);
        var snapshot = Classify(pr: pr, details: details, links: [Sent(pr: pr)]);
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Answered, actual: snapshot.Group);
        Assert.Equal(expected: PRReason.Answered, actual: snapshot.Reason);
        Assert.Equal(expected: "You approved", actual: snapshot.Headline);
        Assert.Equal(expected: "Dana Whitfield sent this in Teams", actual: snapshot.Detail);
        Assert.Equal(expected: T(seconds: -5 * Make.Minute), actual: snapshot.Since);
        Assert.Equal(expected: pr.WebUrl, actual: snapshot.Url);
        Assert.Equal(expected: "Dana Whitfield", actual: snapshot.ChatSource?.Sender);
        Assert.Empty(collection: snapshot.PendingEvents);

        // Seen in the panel, up to when you answered: back to Idle.
        var seen = Classify(pr: pr, details: details, links: [Sent(pr: pr)], cutoff: T(seconds: -5 * Make.Minute));
        Assert.NotNull(@object: seen);
        Assert.Equal(expected: PRGroup.Idle, actual: seen.Group);
        Assert.Equal(expected: PRReason.YouApproved, actual: seen.Reason);
        // Or never seen, for a day.
        Assert.Equal(expected: PRGroup.Answered, actual: Classify(pr: pr, details: details, links: [Sent(pr: pr)], now: T(seconds: -5 * Make.Minute + Make.Day - 1))?.Group);
        Assert.Equal(expected: PRGroup.Idle, actual: Classify(pr: pr, details: details, links: [Sent(pr: pr)], now: T(seconds: -5 * Make.Minute + Make.Day))?.Group);
        // A message that had stopped needing you a week after it came isn't answered by a later vote.
        Assert.Equal(
            expected: PRGroup.Idle,
            actual: Classify(pr: pr, details: details, links: [Sent(pr: pr, at: T(seconds: -8 * Make.Day))], cutoff: T(seconds: -10 * Make.Day))?.Group);
    }

    [Fact]
    public void ACommentAnswersAPullRequestYouAreNotOn()
    {
        var pr = Make.PR(author: People.Alex);
        var thread = new ReviewThread(Id: 3, Comments: [Make.Comment(id: 1, author: People.Me, at: T(seconds: -5 * Make.Minute), text: "Looks good to me")]);
        var snapshot = Classify(pr: pr, role: PRRole.Linked, details: Make.Details(pr: pr, threads: [thread]), links: [Sent(pr: pr)]);
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Answered, actual: snapshot.Group);
        Assert.Equal(expected: "You commented", actual: snapshot.Headline);
        Assert.Equal(expected: "Dana Whitfield sent this in Teams", actual: snapshot.Detail);
        // Once seen, it isn't listed: you're not on it.
        Assert.Null(@object: Classify(pr: pr, role: PRRole.Linked, details: Make.Details(pr: pr, threads: [thread]), links: [Sent(pr: pr)], cutoff: T(seconds: -5 * Make.Minute)));
    }

    [Fact]
    public void RepliesAndMentionsYouAnswered()
    {
        var pr = Make.PR(author: People.Sam, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.Approved)]);
        var reply = new ReviewThread(
            Id: 5,
            Comments:
            [
                Make.Comment(id: 1, author: People.Me, at: T(seconds: -5 * Make.Hour), text: "Why?"),
                Make.Comment(id: 2, author: People.Sam, at: T(seconds: -Make.Hour), text: "Because"),
                Make.Comment(id: 3, author: People.Me, at: T(seconds: -30 * Make.Minute), text: "Fair enough"),
            ]);
        var replied = Classify(pr: pr, details: Make.Details(pr: pr, threads: [reply]));
        Assert.NotNull(@object: replied);
        Assert.Equal(expected: PRGroup.Answered, actual: replied.Group);
        Assert.Equal(expected: "You replied", actual: replied.Headline);
        Assert.Equal(expected: "Sam Rivera replied to you", actual: replied.Detail);
        Assert.Equal(expected: pr.ThreadUrl(threadId: 5), actual: replied.Url);
        Assert.Equal(expected: T(seconds: -30 * Make.Minute), actual: replied.Since);

        var mention = new ReviewThread(
            Id: 6,
            Comments:
            [
                Make.Comment(id: 1, author: People.Priya, at: T(seconds: -Make.Hour), text: "@Robin Diaz is this right?", mentions: [People.Me]),
                Make.Comment(id: 2, author: People.Me, at: T(seconds: -20 * Make.Minute), text: "Yes"),
            ]);
        var mentioned = Classify(pr: pr, details: Make.Details(pr: pr, threads: [reply, mention]));
        Assert.NotNull(@object: mentioned);
        // A mention comes first, as in Needs You; the time is your latest answer.
        Assert.Equal(expected: "Priya Shah mentioned you", actual: mentioned.Detail);
        Assert.Equal(expected: pr.ThreadUrl(threadId: 6), actual: mentioned.Url);
        Assert.Equal(expected: T(seconds: -20 * Make.Minute), actual: mentioned.Since);

        // Comments between others don't concern you as a reviewer, even once you join in.
        var others = new ReviewThread(
            Id: 7,
            Comments:
            [
                Make.Comment(id: 1, author: People.Priya, at: T(seconds: -Make.Hour), text: "Hmm"),
                Make.Comment(id: 2, author: People.Me, at: T(seconds: -Make.Minute), text: "Agreed"),
            ]);
        Assert.Equal(expected: PRGroup.Idle, actual: Classify(pr: pr, details: Make.Details(pr: pr, threads: [others]))?.Group);

        // On your own pull request, any comment needs you, so answering one counts.
        var mine = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.None)]);
        var question = new ReviewThread(
            Id: 8,
            Comments:
            [
                Make.Comment(id: 1, author: People.Sam, at: T(seconds: -Make.Hour), text: "Add a test?"),
                Make.Comment(id: 2, author: People.Me, at: T(seconds: -10 * Make.Minute), text: "Added"),
            ]);
        var answered = Classify(pr: mine, role: PRRole.Author, details: Make.Details(pr: mine, threads: [question]));
        Assert.NotNull(@object: answered);
        Assert.Equal(expected: PRGroup.Answered, actual: answered.Group);
        Assert.Equal(expected: "Sam Rivera commented", actual: answered.Detail);
    }

    [Fact]
    public void VotingOnAReviewRequest()
    {
        var pr = Make.PR(author: People.Sam, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.WaitingForAuthor)]);
        Activity[] activity =
        [
            Added(thread: 1, reviewer: People.Me, by: People.Sam, at: T(seconds: -2 * Make.Hour)),
            Voted(thread: 2, voter: People.Me, vote: Vote.WaitingForAuthor, at: T(seconds: -Make.Hour)),
        ];
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, activity: activity));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Answered, actual: snapshot.Group);
        Assert.Equal(expected: "You asked for changes", actual: snapshot.Headline);
        Assert.Equal(expected: "Sam Rivera asked you to review", actual: snapshot.Detail);
        // Once seen, it waits for the author.
        Assert.Equal(expected: PRGroup.Waiting, actual: Classify(pr: pr, details: Make.Details(pr: pr, activity: activity), cutoff: T(seconds: -Make.Hour))?.Group);
        // A request you'd already seen waited in To Review: nothing to keep in view.
        Assert.Equal(expected: PRGroup.Waiting, actual: Classify(pr: pr, details: Make.Details(pr: pr, activity: activity), cutoff: T(seconds: -90 * Make.Minute))?.Group);

        // Voting on a pull request you weren't asked to review adds you yourself: there was no request.
        var unasked = Make.PR(author: People.Sam, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.Approved)]);
        Activity[] yourOwn =
        [
            Added(thread: 1, reviewer: People.Me, by: People.Me, at: T(seconds: -Make.Hour)),
            Voted(thread: 2, voter: People.Me, vote: Vote.Approved, at: T(seconds: -Make.Hour)),
        ];
        Assert.Equal(expected: PRGroup.Idle, actual: Classify(pr: unasked, details: Make.Details(pr: unasked, activity: yourOwn))?.Group);
    }

    [Fact]
    public void VotingAgainAfterNewCommits()
    {
        var pr = Make.PR(author: People.Sam, created: T(seconds: -5 * Make.Day), reviewers: [new Reviewer(Person: People.Me, Vote: Vote.Approved)]);
        Activity[] activity =
        [
            Voted(thread: 1, voter: People.Me, vote: Vote.WaitingForAuthor, at: T(seconds: -Make.Day)),
            Pushed(thread: 2, pusher: People.Sam, at: T(seconds: -2 * Make.Hour), commits: 2),
            Voted(thread: 3, voter: People.Me, vote: Vote.Approved, at: T(seconds: -Make.Hour)),
        ];
        var snapshot = Classify(pr: pr, details: Make.Details(pr: pr, activity: activity));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Answered, actual: snapshot.Group);
        Assert.Equal(expected: "You approved", actual: snapshot.Headline);
        Assert.Equal(expected: "New commits by Sam Rivera", actual: snapshot.Detail);
    }

    [Fact]
    public void PushingTheChangesSomeoneAskedFor()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.WaitingForAuthor)]);
        Check[] checks = [new(Name: "CI", Kind: CheckKind.Build, State: CheckState.Passed)];
        Activity[] activity =
        [
            Voted(thread: 1, voter: People.Sam, vote: Vote.WaitingForAuthor, at: T(seconds: -2 * Make.Hour)),
            Pushed(thread: 2, pusher: People.Me, at: T(seconds: -Make.Hour), commits: 2),
        ];
        var snapshot = Classify(pr: pr, role: PRRole.Author, details: Make.Details(pr: pr, checks: checks, activity: activity));
        Assert.NotNull(@object: snapshot);
        Assert.Equal(expected: PRGroup.Answered, actual: snapshot.Group);
        Assert.Equal(expected: "You pushed 2 commits", actual: snapshot.Headline);
        Assert.Equal(expected: "Sam Rivera asked for changes", actual: snapshot.Detail);

        // Nor one answering a reviewer who has since been removed: that never needed you.
        var removed = Make.PR(reviewers: [new Reviewer(Person: People.Priya, Vote: Vote.None)]);
        Assert.Equal(expected: PRGroup.Waiting, actual: Classify(pr: removed, role: PRRole.Author, details: Make.Details(pr: removed, checks: checks, activity: activity))?.Group);

        // Someone else's push isn't your answer.
        Activity[] theirs =
        [
            Voted(thread: 1, voter: People.Sam, vote: Vote.WaitingForAuthor, at: T(seconds: -2 * Make.Hour)),
            Pushed(thread: 2, pusher: People.Priya, at: T(seconds: -Make.Hour)),
        ];
        Assert.Equal(expected: PRGroup.Waiting, actual: Classify(pr: pr, role: PRRole.Author, details: Make.Details(pr: pr, checks: checks, activity: theirs))?.Group);
    }

    [Fact]
    public void SomethingElseToDoComesFirst()
    {
        // A failing build on your pull request still shows in Failing.
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.WaitingForAuthor)]);
        Activity[] activity =
        [
            Voted(thread: 1, voter: People.Sam, vote: Vote.WaitingForAuthor, at: T(seconds: -2 * Make.Hour)),
            Pushed(thread: 2, pusher: People.Me, at: T(seconds: -Make.Hour)),
        ];
        Check[] failing = [new(Name: "CI", Kind: CheckKind.Build, State: CheckState.Failed, CompletedAt: T(seconds: -30 * Make.Minute))];
        Assert.Equal(expected: PRGroup.Failing, actual: Classify(pr: pr, role: PRRole.Author, details: Make.Details(pr: pr, checks: failing, activity: activity))?.Group);

        // You answered the message with a comment, but the review is still yours to do; right-click still opens it.
        var review = Make.PR(author: People.Alex, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.None)]);
        var thread = new ReviewThread(Id: 3, Comments: [Make.Comment(id: 1, author: People.Me, at: T(seconds: -5 * Make.Minute), text: "After lunch")]);
        var details = Make.Details(pr: review, threads: [thread], activity: [Added(thread: 1, reviewer: People.Me, by: People.Alex, at: T(seconds: -2 * Make.Day))]);
        var toReview = Classify(pr: review, details: details, links: [Sent(pr: review)], cutoff: T(seconds: -Make.Day));
        Assert.NotNull(@object: toReview);
        Assert.Equal(expected: PRGroup.ToReview, actual: toReview.Group);
        Assert.Equal(expected: "Dana Whitfield", actual: toReview.ChatSource?.Sender);

        // Something new that needs you comes before what you answered.
        var again = new ReviewThread(
            Id: 4, Comments: [Make.Comment(id: 1, author: People.Alex, at: T(seconds: -Make.Minute), text: "@Robin Diaz one more thing", mentions: [People.Me])]);
        var more = Make.Details(pr: review, threads: [thread, again], activity: [Added(thread: 1, reviewer: People.Me, by: People.Alex, at: T(seconds: -2 * Make.Day))]);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: Classify(pr: review, details: more, links: [Sent(pr: review)], cutoff: T(seconds: -Make.Day))?.Group);
    }

    [Fact]
    public void SeeingItInThePanelMovesItOnButNotWhatCameAfter()
    {
        var pr = Make.PR(author: People.Sam, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.Approved)]);
        var thread = new ReviewThread(
            Id: 5,
            Comments:
            [
                Make.Comment(id: 1, author: People.Me, at: T(seconds: -5 * Make.Hour), text: "Why?"),
                Make.Comment(id: 2, author: People.Sam, at: T(seconds: -Make.Hour), text: "Because"),
                Make.Comment(id: 3, author: People.Me, at: T(seconds: -30 * Make.Minute), text: "Fair"),
            ]);
        var seen = new SeenState(baseline: baseline);
        var shown = Classify(pr: pr, details: Make.Details(pr: pr, threads: [thread]), cutoff: seen.Cutoff(key: pr.Key));
        Assert.NotNull(@object: shown);
        Assert.Equal(expected: PRGroup.Answered, actual: shown.Group);

        // Closing the panel marks it seen up to when you answered.
        seen = seen.MarkingSeen(keys: [pr.Key], date: Assert.NotNull(value: shown.Since));
        Assert.Equal(expected: PRGroup.Idle, actual: Classify(pr: pr, details: Make.Details(pr: pr, threads: [thread]), cutoff: seen.Cutoff(key: pr.Key))?.Group);

        // A reply after your answer still needs you.
        var later = thread with { Comments = [.. thread.Comments, Make.Comment(id: 4, author: People.Sam, at: T(seconds: -10 * Make.Minute), text: "Thanks")] };
        Assert.Equal(expected: PRGroup.NeedsYou, actual: Classify(pr: pr, details: Make.Details(pr: pr, threads: [later]), cutoff: seen.Cutoff(key: pr.Key))?.Group);
    }

    /// The Mac announces what a snapshot marks new that it hadn't announced yet, and your pull request failing, becoming
    /// ready or completing; its brief picks from what needs you, fails or is ready. BriefBar for Windows does neither yet:
    /// this checks that what you answered has nothing new, and is in Answered.
    [Fact]
    public void ItsNeitherAnnouncedNorSummarized()
    {
        var unvoted = Make.PR(author: People.Alex);
        var before = Classify(pr: unvoted, role: PRRole.Linked, details: Make.Details(pr: unvoted), links: [Sent(pr: unvoted)]);
        Assert.NotNull(@object: before);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: before.Group);
        var voted = Make.PR(author: People.Alex, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.Approved)]);
        var details = Make.Details(
            pr: voted,
            activity:
            [
                Added(thread: 1, reviewer: People.Me, by: People.Me, at: T(seconds: -Make.Minute)),
                Voted(thread: 2, voter: People.Me, vote: Vote.Approved, at: T(seconds: -Make.Minute)),
            ]);
        var after = Classify(pr: voted, details: details, links: [Sent(pr: voted)]);
        Assert.NotNull(@object: after);
        Assert.Equal(expected: PRGroup.Answered, actual: after.Group);
        Assert.DoesNotContain(collection: after.Events, filter: item => item.IsNew);

        // Nor when your own pull request moves from Needs You to Answered.
        var mine = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.WaitingForAuthor)]);
        Activity[] asked = [Voted(thread: 1, voter: People.Sam, vote: Vote.WaitingForAuthor, at: T(seconds: -2 * Make.Hour))];
        var needsYou = Classify(pr: mine, role: PRRole.Author, details: Make.Details(pr: mine, activity: asked));
        Assert.NotNull(@object: needsYou);
        var pushed = Classify(pr: mine, role: PRRole.Author, details: Make.Details(pr: mine, activity: [.. asked, Pushed(thread: 2, pusher: People.Me, at: T(seconds: -Make.Minute))]));
        Assert.NotNull(@object: pushed);
        Assert.Equal(expected: (PRGroup.NeedsYou, PRGroup.Answered), actual: (needsYou.Group, pushed.Group));
        Assert.DoesNotContain(collection: pushed.Events, filter: item => item.IsNew);
    }

    static PRSnapshot? Classify(
        PullRequest pr,
        PRDetails? details,
        PRRole role = PRRole.Reviewer,
        IEnumerable<ChatLink>? links = null,
        DateTimeOffset? cutoff = null,
        DateTimeOffset? dismissed = null,
        DateTimeOffset? now = null)
    {
        var seenCutoff = cutoff ?? baseline;
        return PRClassifier.Snapshot(
            record: new PRRecord(pullRequest: pr, role: role, me: People.Me.Id, details: details, chatLinks: links),
            seenCutoff: seenCutoff,
            dismissedCutoff: dismissed ?? (seenCutoff < baseline ? seenCutoff : baseline),
            now: now ?? T(seconds: 0));
    }

    /// Dana Whitfield sent `pr` to you in Teams, at `at` or ten minutes before the reference time.
    static ChatLink Sent(PullRequest pr, DateTimeOffset? at = null) => new(
        Link: new PullRequestLink(Organization: pr.Key.Organization, Project: pr.ProjectName, Repository: pr.RepositoryName, Number: pr.Key.Number),
        App: Teams,
        Sender: "Dana Whitfield",
        SentAt: at ?? T(seconds: -10 * Make.Minute),
        NotificationKey: "n1");

    static Activity Voted(int thread, Person voter, Vote vote, DateTimeOffset at) =>
        new(threadId: thread, kind: ActivityKind.Vote, at: at, actor: voter, vote: vote);

    static Activity Pushed(int thread, Person pusher, DateTimeOffset at, int commits = 1) =>
        new(threadId: thread, kind: ActivityKind.Push, at: at, actor: pusher, commitCount: commits);

    static Activity Added(int thread, Person reviewer, Person by, DateTimeOffset at) =>
        new(threadId: thread, kind: ActivityKind.ReviewersChanged, at: at, actor: by, added: [reviewer.Id]);
}
