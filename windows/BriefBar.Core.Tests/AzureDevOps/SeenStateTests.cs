using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;
using static BriefBar.Core.AzureDevOps.SeenState;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// What you've seen and taken off Needs you, kept for each account, and saved. The test named `SeenState`, as on the Mac,
/// hides the type's name in expressions here, so its static members are named on their own.
public sealed class SeenStateTests
{
    /// What BriefBar saved before you could take a pull request off Needs you, and before accounts were told apart.
    /// BriefBar for Windows saves times as seconds since 1970, where the Mac's tests read seconds since 2001.
    const string SavedLongAgo = """{"baseline": 0, "seenAt": {"contoso/1": 864000}}""";

    [Fact]
    public void SeenState()
    {
        var seen = FirstRun(now: T(seconds: 0));
        var key = new PRKey(Organization: "contoso", Number: 1);
        Assert.Equal(expected: T(seconds: -3 * Make.Day), actual: seen.Baseline);
        Assert.Equal(expected: T(seconds: -3 * Make.Day), actual: seen.Cutoff(key: key));
        seen = seen.MarkingSeen(keys: [key], date: T(seconds: 10));
        Assert.Equal(expected: T(seconds: 10), actual: seen.Cutoff(key: key));
        // Never moves back.
        seen = seen.MarkingSeen(keys: [key], date: T(seconds: 5));
        Assert.Equal(expected: T(seconds: 10), actual: seen.Cutoff(key: key));

        seen = seen.MarkingSeen(keys: [new PRKey(Organization: "contoso", Number: 2)], date: T(seconds: -40 * Make.Day));
        seen = seen.MarkingSeen(keys: [new PRKey(Organization: "contoso", Number: 3)], date: T(seconds: -40 * Make.Day));
        seen = seen.Pruning(keeping: new HashSet<PRKey> { new(Organization: "contoso", Number: 3) }, olderThan: T(seconds: -30 * Make.Day));
        Assert.Equal(expected: ["contoso/1", "contoso/3"], actual: seen.SeenAt.Keys.Order(comparer: StringComparer.Ordinal));

        Assert.Equal(expected: seen, actual: SavedAndRead(state: seen));
    }

    [Fact]
    public void TakingAPullRequestOffNeedsYou()
    {
        var seen = FirstRun(now: T(seconds: 0));
        var key = new PRKey(Organization: "contoso", Number: 1);
        Assert.Equal(expected: T(seconds: -3 * Make.Day), actual: seen.DismissedCutoff(key: key));
        seen = seen.MarkingSeen(keys: [key], date: T(seconds: -Make.Hour));
        Assert.Equal(expected: T(seconds: -3 * Make.Day), actual: seen.DismissedCutoff(key: key));

        // It's seen up to then too, and neither moves back.
        seen = seen.Dismissing(keys: [key], date: T(seconds: 0));
        Assert.Equal(expected: T(seconds: 0), actual: seen.DismissedCutoff(key: key));
        Assert.Equal(expected: T(seconds: 0), actual: seen.Cutoff(key: key));
        seen = seen.Dismissing(keys: [key], date: T(seconds: -Make.Minute));
        Assert.Equal(expected: T(seconds: 0), actual: seen.DismissedCutoff(key: key));

        seen = seen.Dismissing(keys: [new PRKey(Organization: "contoso", Number: 2)], date: T(seconds: -40 * Make.Day));
        seen = seen.Pruning(keeping: new HashSet<PRKey>(), olderThan: T(seconds: -30 * Make.Day));
        Assert.Equal(expected: ["contoso/1"], actual: seen.DismissedAt.Keys.Order(comparer: StringComparer.Ordinal));

        Assert.Equal(expected: seen, actual: SavedAndRead(state: seen));
        // Saved before you could: nothing was taken off.
        var earlier = FromJson(node: JsonNode.Parse(json: SavedLongAgo));
        Assert.NotNull(@object: earlier);
        Assert.Empty(collection: earlier.DismissedAt);
        Assert.Equal(expected: DateTimeOffset.UnixEpoch, actual: earlier.DismissedCutoff(key: key));
    }

    /// You took a pull request off Needs you long ago and have looked at it since, then it isn't listed for a while, such
    /// as while its organization isn't chosen. Pruning keeps when you took it off for as long as when you looked at it, so
    /// once it's listed again, what you took off stays off.
    [Fact]
    public void WhatYouTookOffStaysOffWhileWhatYouSawIsKept()
    {
        var key = new PRKey(Organization: "contoso", Number: 7);
        // BriefBar has run for months.
        var seen = FirstRun(now: T(seconds: -200 * Make.Day));
        seen = seen.Dismissing(keys: [key], date: T(seconds: -70 * Make.Day));
        seen = seen.MarkingSeen(keys: [key], date: T(seconds: -Make.Day));
        // Taken off two months ago and more, and not looked at since: it goes, as before.
        seen = seen.Dismissing(keys: [new PRKey(Organization: "contoso", Number: 8)], date: T(seconds: -90 * Make.Day));

        seen = seen.Pruning(keeping: new HashSet<PRKey>(), olderThan: T(seconds: -60 * Make.Day));
        Assert.Equal(expected: ["contoso/7"], actual: seen.SeenAt.Keys.Order(comparer: StringComparer.Ordinal));
        Assert.Equal(expected: ["contoso/7"], actual: seen.DismissedAt.Keys.Order(comparer: StringComparer.Ordinal));
        Assert.Equal(expected: T(seconds: -70 * Make.Day), actual: seen.DismissedCutoff(key: key));

        // Listed again, with recent activity: Sam's comment, which waited on you when you took it off, still doesn't.
        var pr = Make.PR(created: T(seconds: -100 * Make.Day));
        var thread = new ReviewThread(Id: 5, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -80 * Make.Day), text: "Cap it?")]);
        var record = new PRRecord(pullRequest: pr, role: PRRole.Author, me: People.Me.Id, details: Make.Details(pr: pr, threads: [thread], lastActivity: T(seconds: -Make.Hour)));
        PRSnapshot? Classify(DateTimeOffset dismissedCutoff) =>
            PRClassifier.Snapshot(record: record, seenCutoff: seen.Cutoff(key: key), dismissedCutoff: dismissedCutoff, now: T(seconds: 0));
        var listed = Classify(dismissedCutoff: seen.DismissedCutoff(key: key));
        Assert.NotNull(@object: listed);
        Assert.NotEqual(expected: PRGroup.NeedsYou, actual: listed.Group);
        Assert.Empty(collection: listed.PendingEvents);
        // Forgetting only when you took it off would have brought it back.
        Assert.Equal(expected: PRGroup.NeedsYou, actual: Classify(dismissedCutoff: seen.Baseline)?.Group);

        // Once when you looked at it is old enough to go too, both go.
        seen = seen.Pruning(keeping: new HashSet<PRKey>(), olderThan: T(seconds: 0));
        Assert.Empty(collection: seen.SeenAt);
        Assert.Empty(collection: seen.DismissedAt);
    }

    [Fact]
    public void EachAccountHasSeenItsOwn()
    {
        var key = new PRKey(Organization: "contoso", Number: 1);
        // Saved before accounts were told apart: it becomes the account signed in now's.
        var saved = FromJson(node: JsonNode.Parse(json: SavedLongAgo));
        Assert.NotNull(@object: saved);
        var book = new SeenBook(Current: saved, Others: new Dictionary<string, SeenState>());
        Assert.Null(@object: book.Current.Account);
        (book, var switched) = book.SigningIn(account: "tenant/robin", now: T(seconds: 20 * Make.Day));
        Assert.False(condition: switched);
        Assert.Equal(expected: "tenant/robin", actual: book.Current.Account);
        Assert.Equal(expected: DateTimeOffset.UnixEpoch.AddSeconds(seconds: 864_000), actual: book.Current.Cutoff(key: key));

        // Sam signs in: a first run of their own, with Robin's kept.
        book = book with { Current = book.Current.MarkingSeen(keys: [key], date: T(seconds: 10 * Make.Day)) };
        (book, switched) = book.SigningIn(account: "tenant/sam", now: T(seconds: 20 * Make.Day));
        Assert.True(condition: switched);
        Assert.Equal(expected: FirstRun(now: T(seconds: 20 * Make.Day), account: "tenant/sam"), actual: book.Current);
        Assert.Equal(expected: T(seconds: 10 * Make.Day), actual: book.State(account: "tenant/robin", now: T(seconds: 20 * Make.Day)).Cutoff(key: key));
        Assert.Equal(expected: book.Current, actual: book.State(account: "tenant/sam", now: T(seconds: 20 * Make.Day)));
        Assert.Equal(expected: book.Current, actual: book.State(account: null, now: T(seconds: 20 * Make.Day)));
        (book, switched) = book.SigningIn(account: "tenant/sam", now: T(seconds: 30 * Make.Day));
        Assert.False(condition: switched);

        // Robin again: Robin's, and Sam's kept.
        book = book with { Current = book.Current.MarkingSeen(keys: [key], date: T(seconds: 25 * Make.Day)) };
        (book, switched) = book.SigningIn(account: "tenant/robin", now: T(seconds: 30 * Make.Day));
        Assert.True(condition: switched);
        Assert.Equal(expected: T(seconds: 10 * Make.Day), actual: book.Current.Cutoff(key: key));
        Assert.Equal(expected: T(seconds: 25 * Make.Day), actual: book.Others.GetValueOrDefault(key: "tenant/sam")?.Cutoff(key: key));
        Assert.Equal(expected: FirstRun(now: T(seconds: 30 * Make.Day), account: "tenant/kim"), actual: book.State(account: "tenant/kim", now: T(seconds: 30 * Make.Day)));
    }

    /// `state`, saved as text and read back.
    static SeenState? SavedAndRead(SeenState state) => FromJson(node: JsonNode.Parse(json: state.ToJson().ToJsonString()));
}
