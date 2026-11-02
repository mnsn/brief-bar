using System.Globalization;
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
            var snapshot = TeamsDemoData.Snapshot(now: now);
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
                engine!.Publish(snapshot: snapshot);
                await changed.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
                source.Perform(request: new CommandRequest(Section: SectionId.TeamsChats, Command: TeamsCommands.Open, RowId: TeamsDemoData.Avery));
                await source.StopAsync();
            }

            var lines = sink.Lines;
            Assert.Contains(collection: lines, filter: line => line.Contains(value: "teams: Ready, problem none, complete True; 6 chats of 6 conversations, 6 with a read marker; unread 2 chats and 2 group chats, 0 of them marked unread in Teams; recent 1 and 1", comparisonType: StringComparison.Ordinal));
            Assert.Contains(collection: lines, filter: line => line.Contains(value: "unread 1 chats and 2 group chats, 0 of them marked unread in Teams; recent 2 and 1", comparisonType: StringComparison.Ordinal));
            // The chats' IDs and what they hold, rather than the "19:" each ID starts with: every line starts with the time,
            // as HH:mm:ss.fff, which holds "19:" from 19:00 to 19:59 and in minute 19 of every hour. An ID is looked for
            // without that, and the "@…" it ends with, so it's found however it's written. Messages' IDs, and the ones chats
            // are read up to, are numbers, which the log could write.
            var messages = snapshot.Messages.Values.SelectMany(selector: chat => chat)
                .Concat(second: snapshot.Chats.Select(selector: chat => chat.Newest).OfType<TeamsMessage>())
                .ToList();
            var messageIds = messages.Select(selector: message => message.Id)
                .Concat(second: snapshot.Chats.SelectMany(selector: chat => new[] { chat.Marker, chat.MarkedUnread }).OfType<ReadMarker>().Select(selector: marker => marker.MessageId));
            string?[] secrets =
            [
                "Avery", "Quinn", "Sam", "Launch", "Weekly", "deck", "@", "aaaaaaaa", "msteams",
                .. snapshot.Chats.Select(selector: chat => chat.Id["19:".Length..].Split(separator: '@')[0]),
                .. snapshot.Chats.Select(selector: chat => chat.Title),
                .. messages.Select(selector: message => message.Sender),
                .. messages.Select(selector: message => message.Text),
                .. messageIds.Select(selector: id => id.ToString(provider: CultureInfo.InvariantCulture)),
            ];
            foreach (var secret in secrets.OfType<string>())
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
