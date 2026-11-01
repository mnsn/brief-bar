using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Demo;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Opening or seeing a pull request doesn't take a comment that waits on you off Needs you: answering it, or taking the
/// pull request off, does. With the demo's made-up pull requests, as the Mac's `NeedsYouTests`, and others.
public sealed class PRStoreTests
{
    static readonly DateTimeOffset now = TestTimes.T(seconds: 0);
    static readonly PRKey replied = new(Organization: AzureDevOpsDemoData.Organization, Number: 4102);

    [Fact]
    public void WhatYouveSeenStaysUntilYouTakeItOff()
    {
        var (store, settings) = LoadDemo();
        // Sam's reply, which you've seen but not answered, is in Needs you with what's new, and counted with it.
        var seen = Item(store: store, number: 4102);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: seen.Group);
        Assert.False(condition: seen.HasNews);
        Assert.Equal(expected: 2, actual: store.Items.Count(predicate: item => item.Group == PRGroup.NeedsYou && item.HasNews));
        Assert.Equal(expected: 3, actual: store.Counts[PRGroup.NeedsYou]);

        store.Dismiss(item: seen, now: now);
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now), now: now);
        Assert.Equal(expected: PRGroup.Waiting, actual: Item(store: store, number: 4102).Group);
        Assert.Equal(expected: 2, actual: store.Counts[PRGroup.NeedsYou]);
        Assert.Equal(expected: seen.Since, actual: settings.DismissedCutoff(key: replied));
    }

    [Fact]
    public void MarkAsSeenKeepsWhatWaitsOnYou()
    {
        var (store, _) = LoadDemo();
        store.Clear(group: PRGroup.NeedsYou, now: now);
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now), now: now);
        // The review request waits in To review; the reply and the mention stay.
        Assert.Equal(expected: PRGroup.ToReview, actual: Item(store: store, number: 4110).Group);
        var needsYou = store.Items.Where(predicate: item => item.Group == PRGroup.NeedsYou).ToList();
        Assert.Equal(expected: [4097, 4102], actual: needsYou.Select(selector: item => item.Key.Number).Order());
        Assert.DoesNotContain(collection: needsYou, filter: item => item.HasNews);
        Assert.Equal(expected: 2, actual: store.Counts[PRGroup.NeedsYou]);
    }

    /// Opening a pull request sees it up to now, or up to its newest news if that's later, as a clock that's behind can make
    /// it.
    [Fact]
    public void OpeningSeesItUpToNow()
    {
        var (store, settings) = LoadDemo();
        var mentioned = Item(store: store, number: 4097);
        Assert.True(condition: mentioned.HasNews);
        store.MarkSeen(item: mentioned, now: now);
        Assert.Equal(expected: now, actual: settings.SeenCutoff(key: mentioned.Key));
        store.Recompute(now: now);
        var seen = Item(store: store, number: 4097);
        Assert.Equal(expected: PRGroup.NeedsYou, actual: seen.Group);
        Assert.False(condition: seen.HasNews);
    }

    /// Clear sees what Done shows, which empties it, but for a pull request whose pipelines still run or wait after it
    /// merged: that shows whether or not you've seen it, as on the Mac.
    [Fact]
    public void ClearingDoneKeepsOnlyWhatStillRunsAfterItMerged()
    {
        var (store, _) = LoadDemo();
        var abandoned = new PRRecord(
            pullRequest: Make.PR(
                number: 4120, title: "Try another font", status: PullRequestStatus.Abandoned, closed: now.AddMinutes(minutes: -30), organization: AzureDevOpsDemoData.Organization),
            role: PRRole.Author,
            me: People.Me.Id);
        var demo = AzureDevOpsDemoData.Snapshot(now: now);
        store.Receive(snapshot: demo with { Records = [.. demo.Records, abandoned] }, now: now);
        Assert.Equal(expected: 2, actual: store.Counts[PRGroup.Done]);

        store.Clear(group: PRGroup.Done, now: now);
        store.Recompute(now: now);
        var waiting = Assert.Single(collection: store.Items, predicate: item => item.Group == PRGroup.Done);
        Assert.Equal(expected: 4085, actual: waiting.Key.Number);
        Assert.Equal(expected: PRReason.WaitingForApproval, actual: waiting.Reason);
    }

    /// What the panel shows in Answered stays there while it's open, and is seen once it closes, up to when you answered
    /// it: then it goes back to its usual group.
    [Fact]
    public void AnsweredStaysUntilThePanelCloses()
    {
        var (store, settings) = LoadDemo();
        var answered = Assert.Single(collection: store.Items, predicate: item => item.Group == PRGroup.Answered);
        store.PanelOpened(now: now);
        store.Recompute(now: now.AddMinutes(minutes: 1));
        Assert.Equal(expected: PRGroup.Answered, actual: Item(store: store, number: answered.Key.Number).Group);

        store.PanelClosed();
        Assert.Equal(expected: answered.Since, actual: settings.SeenCutoff(key: answered.Key));
        store.Recompute(now: now.AddMinutes(minutes: 1));
        Assert.Equal(expected: PRGroup.Idle, actual: Item(store: store, number: answered.Key.Number).Group);
        // Closing it again sees nothing more.
        store.PanelClosed();
    }

    /// A panel that never showed Answered sees nothing as it closes.
    [Fact]
    public void ClosingAPanelThatWasntOpenSeesNothing()
    {
        var (store, settings) = LoadDemo();
        var answered = Assert.Single(collection: store.Items, predicate: item => item.Group == PRGroup.Answered);
        var before = settings.SeenCutoff(key: answered.Key);
        store.PanelClosed();
        Assert.Equal(expected: before, actual: settings.SeenCutoff(key: answered.Key));
    }

    /// Someone else signs in to the Azure CLI: what they've seen is their own, and the last account's comes back with it.
    [Fact]
    public void EachAccountSeesItsOwn()
    {
        var (store, settings) = LoadDemo();
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now) with { Account = "tenant/robin" }, now: now);
        Assert.Equal(expected: "tenant/robin", actual: settings.Account);
        Assert.False(condition: Item(store: store, number: 4102).HasNews);

        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now) with { Account = "tenant/sam" }, now: now);
        Assert.Equal(expected: "tenant/sam", actual: settings.Account);
        // Sam has seen nothing of Robin's: the reply Robin opened is new to Sam.
        Assert.True(condition: Item(store: store, number: 4102).HasNews);

        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now) with { Account = "tenant/robin" }, now: now);
        Assert.False(condition: Item(store: store, number: 4102).HasNews);
    }

    /// The pull requests you watch are listed as watched; those the engine read as closed aren't watched anymore.
    [Fact]
    public void ListsWhatYouWatchUntilItCloses()
    {
        var (store, settings) = LoadDemo();
        var link = new PullRequestLink(Organization: AzureDevOpsDemoData.Organization, Project: "Storefront", Repository: "search", Number: 4071);
        Assert.True(condition: settings.Watch(link: link));
        store.Recompute(now: now);
        Assert.True(condition: Item(store: store, number: 4071).IsWatched);
        Assert.False(condition: Item(store: store, number: 4102).IsWatched);

        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now) with { ClosedLinks = new HashSet<PRKey> { link.Key } }, now: now);
        Assert.Empty(collection: settings.WatchedPullRequests);
        Assert.False(condition: Item(store: store, number: 4071).IsWatched);
    }

    /// While it finds your organizations, the panel says so rather than the engine's "no organizations"; if that fails, it
    /// says why, and tries again a minute later; once found, nothing's wrong.
    [Fact]
    public void SaysHowFindingYourOrganizationsGoes()
    {
        var settings = new AzureDevOpsSettings(settings: new MemorySettings(), now: now);
        var store = new PRStore(settings: settings);
        store.Receive(snapshot: new PulseSnapshot { Problem = PulseProblem.NoOrganizations, HasLoaded = true }, now: now);
        Assert.True(condition: store.NeedsDiscovery);
        Assert.Null(@object: store.Problem);

        Assert.True(condition: store.StartDiscovery(now: now));
        Assert.False(condition: store.StartDiscovery(now: now));
        Assert.False(condition: store.NeedsDiscovery);
        Assert.Null(@object: store.Problem);

        var signedOut = new PulseProblem(Kind: PulseProblemKind.SignedOut);
        store.DiscoveryFailed(problem: signedOut);
        Assert.Equal(expected: signedOut, actual: store.Problem);
        Assert.False(condition: store.ShouldRetryDiscovery(now: now.AddSeconds(seconds: 30)));
        Assert.True(condition: store.ShouldRetryDiscovery(now: now.AddSeconds(seconds: 61)));

        Assert.True(condition: store.StartDiscovery(now: now.AddSeconds(seconds: 61)));
        settings.Organizations = [AzureDevOpsDemoData.Organization];
        settings.HasDiscovered = true;
        store.DiscoveryFinished();
        Assert.False(condition: store.NeedsDiscovery);
        // The engine hasn't read the organizations just found: that isn't a problem.
        Assert.Null(@object: store.Problem);
    }

    /// Found, but none has a pull request of yours: the engine's "no organizations" stands.
    [Fact]
    public void SaysWhenNoOrganizationIsWatched()
    {
        var settings = new AzureDevOpsSettings(settings: new MemorySettings(), now: now) { HasDiscovered = true };
        var store = new PRStore(settings: settings);
        store.Receive(snapshot: new PulseSnapshot { Problem = PulseProblem.NoOrganizations, HasLoaded = true }, now: now);
        Assert.False(condition: store.NeedsDiscovery);
        Assert.Equal(expected: PulseProblemKind.NoOrganizations, actual: store.Problem?.Kind);
    }

    /// The demo's pull requests and seen state, as `AzureDevOpsSource` starts them.
    static (PRStore Store, AzureDevOpsSettings Settings) LoadDemo()
    {
        var settings = AzureDevOpsDemoData.Settings(storage: new MemorySettings(), now: now);
        var store = new PRStore(settings: settings);
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now), now: now);
        return (store, settings);
    }

    static PRSnapshot Item(PRStore store, int number) => Assert.Single(collection: store.Items, predicate: item => item.Key.Number == number);
}
