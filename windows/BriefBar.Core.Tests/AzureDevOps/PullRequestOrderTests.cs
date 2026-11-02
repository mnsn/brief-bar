using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Demo;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Ported from the `PullRequestOrderTests` suite in Tests/AzureDevOpsUITests/PullRequestOrderTests.swift: how you sort the
/// pull requests is a choice kept in the settings, by status until you make it; by date, the list has every pull request
/// it has by status, by when each was created. With the made-up pull requests, which never use the Azure CLI or Azure
/// DevOps.
public sealed class PullRequestOrderTests
{
    static readonly DateTimeOffset now = TestTimes.T(seconds: 0);

    [Fact]
    public void ByStatusUntilYouChoose()
    {
        var storage = new MemorySettings();
        var settings = new AzureDevOpsSettings(settings: storage, now: now);
        Assert.Equal(expected: PROrder.Status, actual: settings.PullRequestOrder);

        settings.PullRequestOrder = PROrder.OldestFirst;
        // Kept for the next start, as the Mac keeps it.
        Assert.Equal(expected: PROrder.OldestFirst, actual: new AzureDevOpsSettings(settings: storage, now: now).PullRequestOrder);
        Assert.Equal(expected: "oldestFirst", actual: storage.Read(key: AzureDevOpsSettings.PullRequestOrderKey)?.GetValue<string>());

        // Something else in the settings, by status.
        storage.Write(key: AzureDevOpsSettings.PullRequestOrderKey, value: JsonValue.Create(value: "sideways"));
        Assert.Equal(expected: PROrder.Status, actual: new AzureDevOpsSettings(settings: storage, now: now).PullRequestOrder);
        storage.Write(key: AzureDevOpsSettings.PullRequestOrderKey, value: JsonValue.Create(value: 2));
        Assert.Equal(expected: PROrder.Status, actual: new AzureDevOpsSettings(settings: storage, now: now).PullRequestOrder);
        Assert.Throws<ArgumentOutOfRangeException>(testCode: () => settings.PullRequestOrder = (PROrder)7);
    }

    [Fact]
    public void ByDateListsTheSamePullRequestsByWhenEachWasCreated()
    {
        var store = new PRStore(settings: AzureDevOpsDemoData.Settings(storage: new MemorySettings(), now: now));
        store.Receive(snapshot: AzureDevOpsDemoData.Snapshot(now: now), now: now);
        Assert.NotEmpty(collection: store.Items);
        Assert.Equal(expected: store.Items, actual: store.ItemsBy(order: PROrder.Status));

        var newest = store.ItemsBy(order: PROrder.NewestFirst);
        var oldest = store.ItemsBy(order: PROrder.OldestFirst);
        var keys = store.Items.Select(selector: item => item.Key).ToHashSet();
        Assert.True(condition: keys.SetEquals(other: newest.Select(selector: item => item.Key)));
        Assert.True(condition: keys.SetEquals(other: oldest.Select(selector: item => item.Key)));
        var created = oldest.Select(selector: item => item.CreatedAt ?? DateTimeOffset.MaxValue).ToList();
        Assert.Equal(expected: created.Order(), actual: created);
        var newestCreated = newest.Select(selector: item => item.CreatedAt ?? DateTimeOffset.MinValue).ToList();
        Assert.Equal(expected: newestCreated.OrderDescending(), actual: newestCreated);
        // What the status order counts stays as it was.
        Assert.Equal(expected: store.Counts, actual: new GroupCounts(snapshots: newest));

        // In one list, all but Done's and Idle's, which keep their own sections.
        var listed = store.DateList(order: PROrder.OldestFirst);
        Assert.Equal(expected: oldest.Where(predicate: item => item.Group is not (PRGroup.Done or PRGroup.Idle)), actual: listed);
        Assert.Equal(expected: store.Items.Count - store.Counts[PRGroup.Done] - store.Counts[PRGroup.Idle], actual: listed.Count);
        var groups = listed.Select(selector: item => item.Group).ToHashSet();
        Assert.Contains(expected: PRGroup.NeedsYou, collection: groups);
        Assert.Contains(expected: PRGroup.Ready, collection: groups);
    }
}
