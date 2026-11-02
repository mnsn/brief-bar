using System.Text;
using BriefBar.Core.Copilot;
using static BriefBar.Core.Tests.Copilot.Line;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class EventLogReaderTests
{
    public static TheoryData<string, bool, string[], string> Splits { get; } = new()
    {
        { "a\nb\nc", false, ["a", "b"], "c" },
        { "a\nb\n", false, ["a", "b"], "" },
        { "\n\na\n", false, ["a"], "" },
        { "x", false, [], "x" },
        { "", false, [], "" },
        { "partial\nb\nc", true, ["b"], "c" },
        { "\nb\n", true, ["b"], "" },
        { "no newline", true, [], "" },
    };

    [Fact]
    public void LoadsAndThenFollowsAppends()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines:
        [
            SessionStart(at: T(seconds: 0)),
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["c1"]),
            ToolStart(name: "bash", id: "c1", at: T(seconds: 3), arguments: new() { ["description"] = "Build" }),
        ]);

        var reader = new EventLogReader(path: path);
        Assert.True(condition: reader.Update());
        Assert.True(condition: reader.IsLoaded);
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 1), detail: "Build"), actual: reader.State.Activity);
        Assert.False(condition: reader.Update());

        AppendLog(path: path, lines: [ToolComplete(id: "c1", at: T(seconds: 4)), AssistantMessage(at: T(seconds: 5)), TurnEnd(at: T(seconds: 6))]);
        Assert.True(condition: reader.Update());
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 6), summary: null), actual: reader.State.Activity);
        Assert.False(condition: reader.Update());
    }

    [Fact]
    public void WaitsForPartialLinesToComplete()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines: [UserMessage(at: T(seconds: 1))]);
        var reader = new EventLogReader(path: path);
        reader.Update();

        var line = PermissionRequested(id: "r1", request: new() { ["kind"] = "shell", ["fullCommandText"] = "make" }, at: T(seconds: 2));
        AppendRaw(path: path, text: line[..(line.Length / 2)]);
        Assert.False(condition: reader.Update());
        Assert.Empty(collection: reader.State.PendingPermissions);

        AppendRaw(path: path, text: line[(line.Length / 2)..] + "\n");
        Assert.True(condition: reader.Update());
        Assert.Equal(
            expected: LogActivity.NeedsPermission(permission: new PendingPermission { RequestId = "r1", Kind = "shell", Detail = "make", RequestedAt = T(seconds: 2) }),
            actual: reader.State.Activity);
    }

    [Fact]
    public void GrowsTheTailUntilItReachesTheStartOfTheTurn()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines:
        [
            SessionStart(at: T(seconds: 0)),
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["c1"]),
            ToolStart(name: "bash", id: "c1", at: T(seconds: 3), arguments: new() { ["description"] = "Build" }),
            .. Enumerable.Range(start: 0, count: 20).Select(selector: index => Filler(bytes: 300, at: T(seconds: 4 + index))),
        ]);

        var reader = new EventLogReader(path: path, tailChunkSizes: [512, 2_048, 1 << 20]);
        reader.Update();
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 1), detail: "Build"), actual: reader.State.Activity);
        Assert.Equal(expected: ["c1"], actual: reader.State.PendingTools.Keys.Order());
        Assert.Equal(expected: T(seconds: 23), actual: reader.State.LastEventAt);

        // Without room to grow, the same file shows no turn at all.
        var shortSighted = new EventLogReader(path: path, tailChunkSizes: [512]);
        shortSighted.Update();
        Assert.Equal(expected: LogPhase.Unknown, actual: shortSighted.State.Phase);
        Assert.Equal(expected: T(seconds: 23), actual: shortSighted.State.LastEventAt);
    }

    [Fact]
    public void IgnoresHistoryBeforeTheLatestTurn()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        string[] lines =
        [
            UserMessage(at: T(seconds: 0), content: "Old request"),
            ToolStart(name: "ask_user", id: "old", at: T(seconds: 1), arguments: new() { ["question"] = "Old question?" }),
            .. Enumerable.Range(start: 0, count: 10).Select(selector: index => Filler(bytes: 300, at: T(seconds: 10 + index))),
            UserMessage(at: T(seconds: 100), content: "New request"),
            ToolStart(name: "bash", id: "new", at: T(seconds: 101)),
        ];
        WriteLog(path: path, lines: lines);

        var reader = new EventLogReader(path: path, tailChunkSizes: [1_024, 1 << 20]);
        reader.Update();
        Assert.Equal(expected: ["new"], actual: reader.State.PendingTools.Keys.Order());
        Assert.Equal(expected: T(seconds: 100), actual: reader.State.PhaseSince);
        // Replaying everything would have kept the old, never-answered question.
        Assert.Equal(expected: ["new", "old"], actual: LogState(lines: lines).PendingTools.Keys.Order());
    }

    /// Windows can give a file that replaces another within moments the first one's creation time (file system
    /// tunneling), so the bytes the reader read before tell the swap.
    [Fact]
    public void ReloadsAReplacedFile()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines: [UserMessage(at: T(seconds: 1)), AssistantMessage(at: T(seconds: 2)), TurnEnd(at: T(seconds: 3))]);
        var reader = new EventLogReader(path: path);
        reader.Update();
        Assert.Equal(expected: LogPhase.Finished, actual: reader.State.Phase);

        // Larger than the original.
        var replacement = folder.Combine("replacement.jsonl");
        WriteLog(path: replacement, lines: [UserMessage(at: T(seconds: 10)), Filler(bytes: 2_000, at: T(seconds: 11))]);
        File.Delete(path: path);
        File.Move(sourceFileName: replacement, destFileName: path);

        Assert.True(condition: reader.Update());
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 10), detail: null), actual: reader.State.Activity);
    }

    [Fact]
    public void ReloadsATruncatedFile()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines: [UserMessage(at: T(seconds: 1)), AssistantMessage(at: T(seconds: 2)), TurnEnd(at: T(seconds: 3))]);
        var reader = new EventLogReader(path: path);
        reader.Update();
        var before = FileStamp.Of(path: path);

        Rewrite(path: path, lines: [UserMessage(at: T(seconds: 20))]);
        Assert.Equal(expected: before?.Id, actual: FileStamp.Of(path: path)?.Id);

        Assert.True(condition: reader.Update());
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 20), detail: null), actual: reader.State.Activity);
    }

    [Fact]
    public void ReloadsAFileRewrittenInPlace()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines: [UserMessage(at: T(seconds: 1)), AssistantMessage(at: T(seconds: 2)), TurnEnd(at: T(seconds: 3))]);
        var reader = new EventLogReader(path: path);
        reader.Update();
        var before = FileStamp.Of(path: path)!.Value;

        // The same file, now larger than before, so only its changed contents reveal the rewrite.
        Rewrite(path: path, lines: [UserMessage(at: T(seconds: 20)), Filler(bytes: 2_000, at: T(seconds: 21))]);
        var after = FileStamp.Of(path: path)!.Value;
        Assert.Equal(expected: before.Id, actual: after.Id);
        Assert.True(condition: after.Size > before.Size);

        Assert.True(condition: reader.Update());
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 20), detail: null), actual: reader.State.Activity);
        Assert.Equal(expected: T(seconds: 21), actual: reader.State.LastEventAt);
    }

    [Fact]
    public void ReloadsAFileRewrittenToTheSameSize()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines: [UserMessage(at: T(seconds: 1), content: "Fix A"), ToolStart(name: "bash", id: "c1", at: T(seconds: 2))]);
        var reader = new EventLogReader(path: path);
        reader.Update();
        Assert.Equal(expected: ["c1"], actual: reader.State.PendingTools.Keys.Order());
        var before = FileStamp.Of(path: path)!.Value;

        Rewrite(path: path, lines: [UserMessage(at: T(seconds: 5), content: "Fix B"), ToolStart(name: "bash", id: "c2", at: T(seconds: 6))]);
        // The rewrite shows even on a clock too coarse to tell the writes apart.
        File.SetLastWriteTimeUtc(path: path, lastWriteTimeUtc: DateTime.UtcNow.AddSeconds(value: 10));
        var after = FileStamp.Of(path: path)!.Value;
        Assert.True(condition: after.Id == before.Id && after.Size == before.Size);

        Assert.True(condition: reader.Update());
        Assert.Equal(expected: ["c2"], actual: reader.State.PendingTools.Keys.Order());
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 5), detail: null), actual: reader.State.Activity);
        Assert.False(condition: reader.Update());

        // A changed time alone isn't a rewrite.
        File.SetLastWriteTimeUtc(path: path, lastWriteTimeUtc: DateTime.UtcNow.AddSeconds(value: 20));
        Assert.False(condition: reader.Update());
        AppendLog(path: path, lines: [ToolComplete(id: "c2", at: T(seconds: 7))]);
        Assert.True(condition: reader.Update());
        Assert.Empty(collection: reader.State.PendingTools);
        Assert.Equal(expected: T(seconds: 5), actual: reader.State.PhaseSince);
    }

    [Fact]
    public void AColdResumeEndsTheTurnWhetherAppendedOrInTheTail()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines: [UserMessage(at: T(seconds: 1)), ToolStart(name: "ask_user", id: "q", at: T(seconds: 2), arguments: new() { ["question"] = "Ship it?" })]);
        var reader = new EventLogReader(path: path);
        reader.Update();
        Assert.Equal(expected: ["q"], actual: reader.State.PendingTools.Keys.Order());

        AppendLog(path: path, lines: [Resume(at: T(seconds: 60))]);
        Assert.True(condition: reader.Update());
        Assert.Equal(expected: LogActivity.Interrupted(at: T(seconds: 2)), actual: reader.State.Activity);

        // A fresh load starts at the last message, before the resume.
        var fresh = new EventLogReader(path: path);
        fresh.Update();
        Assert.Equal(expected: LogActivity.Interrupted(at: T(seconds: 2)), actual: fresh.State.Activity);
        Assert.Empty(collection: fresh.State.PendingTools);
    }

    [Fact]
    public void WaitsForTheFileToAppear()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("session", "events.jsonl");
        var reader = new EventLogReader(path: path);
        Assert.False(condition: reader.Update());
        Assert.False(condition: reader.IsLoaded);

        WriteLog(path: path, lines: []);
        Assert.True(condition: reader.Update());
        Assert.True(condition: reader.IsLoaded);
        Assert.Equal(expected: new SessionLogState(), actual: reader.State);

        AppendLog(path: path, lines: [UserMessage(at: T(seconds: 1))]);
        Assert.True(condition: reader.Update());
        Assert.Equal(expected: LogPhase.Running, actual: reader.State.Phase);
    }

    [Fact]
    public void RereadsTheTailAfterAnOversizedAppend()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines: [UserMessage(at: T(seconds: 1)), ToolStart(name: "bash", id: "c1", at: T(seconds: 2))]);
        var reader = new EventLogReader(path: path, tailChunkSizes: [600], maxIncrementalRead: 256);
        reader.Update();
        Assert.Equal(expected: ["c1"], actual: reader.State.PendingTools.Keys.Order());

        AppendLog(path: path, lines: [Filler(bytes: 2_000, at: T(seconds: 3)), ToolStart(name: "ask_user", id: "q", at: T(seconds: 4), arguments: new() { ["question"] = "Proceed?" })]);
        Assert.True(condition: reader.Update());
        // Only the new tail was read, so the earlier call went with the history before it.
        Assert.Equal(expected: ["q"], actual: reader.State.PendingTools.Keys.Order());
        Assert.Equal(expected: T(seconds: 4), actual: reader.State.PhaseSince);

        // Small appends are still read as they come.
        AppendLog(path: path, lines: [ToolComplete(id: "q", at: T(seconds: 5))]);
        Assert.True(condition: reader.Update());
        Assert.Empty(collection: reader.State.PendingTools);
        Assert.Equal(expected: T(seconds: 4), actual: reader.State.PhaseSince);
    }

    /// The reader never keeps the log open: the app writing it can delete or replace it at any moment, as Windows lets
    /// it only while nobody holds it without sharing that.
    [Fact]
    public void LetsTheLogBeDeletedAtAnyTime()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("events.jsonl");
        WriteLog(path: path, lines: [UserMessage(at: T(seconds: 1)), ToolStart(name: "bash", id: "c1", at: T(seconds: 2))]);
        var reader = new EventLogReader(path: path);
        reader.Update();
        File.Delete(path: path);
        Assert.False(condition: File.Exists(path: path));
        // Gone, it keeps what it knew; the session list decides what shows.
        Assert.False(condition: reader.Update());
        Assert.Equal(expected: ["c1"], actual: reader.State.PendingTools.Keys);
    }

    [Theory]
    [MemberData(memberName: nameof(Splits))]
    public void SplitsLines(string text, bool skipFirstPartial, string[] expectedLines, string expectedRest)
    {
        var lines = new List<string>();
        var rest = EventLogReader.ForEachLine(data: Encoding.UTF8.GetBytes(s: text), skipFirstPartial: skipFirstPartial, body: line =>
            lines.Add(item: Encoding.UTF8.GetString(bytes: line)));
        Assert.Equal(expected: expectedLines, actual: lines);
        Assert.Equal(expected: expectedRest, actual: Encoding.UTF8.GetString(bytes: rest));
    }

    internal static void WriteLog(string path, IEnumerable<string> lines)
    {
        Directory.CreateDirectory(path: Path.GetDirectoryName(path: path)!);
        File.WriteAllText(path: path, contents: string.Concat(values: lines.Select(selector: line => line + "\n")));
    }

    internal static void AppendLog(string path, IEnumerable<string> lines) =>
        AppendRaw(path: path, text: string.Concat(values: lines.Select(selector: line => line + "\n")));

    static void AppendRaw(string path, string text) => File.AppendAllText(path: path, contents: text);

    /// Replaces the file's contents without replacing the file.
    static void Rewrite(string path, IEnumerable<string> lines)
    {
        using var stream = new FileStream(path: path, mode: FileMode.Open, access: FileAccess.Write, share: FileShare.ReadWrite | FileShare.Delete);
        stream.SetLength(value: 0);
        var bytes = Encoding.UTF8.GetBytes(s: string.Concat(values: lines.Select(selector: line => line + "\n")));
        stream.Write(buffer: bytes, offset: 0, count: bytes.Length);
    }
}
