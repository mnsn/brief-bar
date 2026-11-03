using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Watching an organization, or stopping, as Settings' switch, Add an organization and its check do: one step, which
/// changes nothing when it's that way already, by any spelling, so that two at once never undo each other.
public sealed class WatchingOrganizationsTests
{
    /// Enough rounds that two who each look whether it's watched, then switch it, undo each other in some: tried that way,
    /// the test fails.
    const int Rounds = 2000;
    static readonly DateTimeOffset now = TestTimes.T(seconds: 0);

    [Fact]
    public void WatchesOrStopsOnlyWhenThatChangesSomething()
    {
        var storage = new MemorySettings();
        var settings = new AzureDevOpsSettings(settings: storage, now: now);
        var changes = 0;
        settings.Changed += (_, _) => changes++;

        settings.SetWatching(name: "Fabrikam", watching: true);
        Assert.Equal(expected: ["Fabrikam"], actual: settings.Organizations);
        Assert.Equal(expected: 1, actual: changes);
        // Watched already, by any spelling: nothing changes, nor is saved again.
        settings.SetWatching(name: "fabrikam", watching: true);
        Assert.Equal(expected: ["Fabrikam"], actual: settings.Organizations);
        Assert.Equal(expected: 1, actual: changes);

        // Stopped, by any spelling, once.
        settings.SetWatching(name: "FABRIKAM", watching: false);
        Assert.Empty(collection: settings.Organizations);
        settings.SetWatching(name: "fabrikam", watching: false);
        Assert.Equal(expected: 2, actual: changes);
        Assert.Empty(collection: new AzureDevOpsSettings(settings: storage, now: now).Organizations);
    }

    /// The check of an organization you add ends just as you switch it on in Settings: it's watched, once, whoever comes
    /// first. Two who each looked whether it's watched, then switched it, could both find it off, and turn it on, then off.
    [Fact]
    public void TwoWatchingAtOnceLeaveItWatched()
    {
        for (var round = 0; round < Rounds; round++)
        {
            var settings = new AzureDevOpsSettings(settings: new MemorySettings(), now: now);
            using var together = new Barrier(participantCount: 2);
            var check = new Thread(start: () =>
            {
                together.SignalAndWait();
                settings.SetWatching(name: "fabrikam", watching: true);
            });
            var you = new Thread(start: () =>
            {
                together.SignalAndWait();
                settings.SetWatching(name: "Fabrikam", watching: true);
            });
            check.Start();
            you.Start();
            check.Join();
            you.Join();
            Assert.Single(collection: settings.Organizations);
        }
    }
}
