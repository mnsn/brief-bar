using BriefBar.Core.Demo;
using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;
using BriefBar.Core.Teams;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.Teams;

/// What Teams writes to BriefBar's log: how its sections stand, in counts, and never a name, a message or an ID.
[Collection(name: nameof(SharedLog))]
public sealed class TeamsSourceLogTests
{
    [Fact]
    public async Task LogsCountsButNoChats()
    {
        var sink = new ListSink();
        Log.UseSink(newSink: sink);
        try
        {
            using var folder = new TemporaryFolder();
            var now = Times.At(seconds: 0);
            FakeTeamsEngine? engine = null;
            var source = new TeamsSource(
                settings: new TeamsSettings(settings: new MemorySettings()),
                makeEngine: onChange => engine = new FakeTeamsEngine(onChange: onChange),
                access: new TeamsAccess(OpenLink: _ => { }, OpenApp: () => { }),
                makeMarks: () => new TeamsReadMarks(path: folder.Combine("Teams", "read"), protector: new FakeProtector()),
                time: new TestClock(start: now));
            using (source)
            {
                await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
                await Waiting.Until(condition: () => engine is { Starts: > 0 });
                var changed = Waiting.NextChange(source: source);
                engine!.Publish(snapshot: TeamsDemoData.Snapshot(now: now));
                await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
                source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: TeamsCommands.Open, RowId: TeamsDemoData.Avery));
                await source.StopAsync();
            }

            var lines = sink.Lines;
            Assert.Contains(collection: lines, filter: line => line.Contains(value: "teams: Ready, problem none, complete True; 6 chats of 6 conversations, 6 with a read marker; unread 2 chats and 2 group chats, 0 of them marked unread in Teams; recent 1 and 1", comparisonType: StringComparison.Ordinal));
            Assert.Contains(collection: lines, filter: line => line.Contains(value: "unread 1 chats and 2 group chats, 0 of them marked unread in Teams; recent 2 and 1", comparisonType: StringComparison.Ordinal));
            foreach (var secret in new[] { "Avery", "Quinn", "Sam", "Launch", "Weekly", "deck", "19:", "@", "aaaaaaaa", "msteams" })
            {
                Assert.DoesNotContain(collection: lines, filter: line => line.Contains(value: secret, comparisonType: StringComparison.Ordinal));
            }
        }
        finally
        {
            Log.UseSink(newSink: null);
        }
    }
}
