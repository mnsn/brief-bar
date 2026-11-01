using BriefBar.Core.Logging;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Logging;

[Collection(name: nameof(SharedLog))]
public sealed class LogTests
{
    [Fact]
    public void WritesNumbersStatesAndIdsWithATime()
    {
        var sink = new ListSink();
        Log.UseSink(newSink: sink);
        try
        {
            var count = 3;
            var target = PanelTarget.Of(section: SectionId.CopilotSessions);
            Log.Write(line: $"panel {target}: {count} rows, {ItemState.NeedsYou} first, open {true}, at {new PixelRect(Left: 1, Top: 2, Width: 3, Height: 4)}");
            var line = Assert.Single(collection: sink.Lines);
            Assert.Matches(expectedRegexPattern: @"^\d\d:\d\d:\d\d\.\d\d\d ", actualString: line);
            Assert.EndsWith(
                expectedEndString: "panel copilot.sessions: 3 rows, NeedsYou first, open True, at 1,2 3x4",
                actualString: line,
                comparisonType: StringComparison.Ordinal);
        }
        finally
        {
            Log.UseSink(newSink: null);
        }
    }

    [Fact]
    public void WritesAnErrorsTypeButNotItsMessage()
    {
        var sink = new ListSink();
        Log.UseSink(newSink: sink);
        try
        {
            var error = Thrown(message: "Made-up title that must not reach the log");
            Log.Write(error: error, context: $"reading {SectionId.CopilotSessions}");
            var line = Assert.Single(collection: sink.Lines);
            Assert.Contains(
                expectedSubstring: "reading copilot.sessions: InvalidOperationException, HRESULT 0x80131509, at LogTests.Thrown",
                actualString: line,
                comparisonType: StringComparison.Ordinal);
            Assert.DoesNotContain(expectedSubstring: "Made-up title", actualString: line, comparisonType: StringComparison.Ordinal);
            Assert.DoesNotContain(expectedSubstring: ".cs", actualString: line, comparisonType: StringComparison.Ordinal);
        }
        finally
        {
            Log.UseSink(newSink: null);
        }
    }

    [Fact]
    public void WritesTheInnerErrorsTypeButNotItsMessage()
    {
        var sink = new ListSink();
        Log.UseSink(newSink: sink);
        try
        {
            var error = new InvalidOperationException(
                message: "Made-up outer message",
                innerException: Thrown(message: "Made-up inner message"));
            Log.Write(error: error, context: $"reading {SectionId.CopilotSessions}");
            var line = Assert.Single(collection: sink.Lines);
            Assert.Contains(
                expectedSubstring: "; from InvalidOperationException, HRESULT 0x80131509, at LogTests.Thrown",
                actualString: line,
                comparisonType: StringComparison.Ordinal);
            Assert.DoesNotContain(expectedSubstring: "Made-up", actualString: line, comparisonType: StringComparison.Ordinal);
        }
        finally
        {
            Log.UseSink(newSink: null);
        }
    }

    [Fact]
    public void GoesNowhereWithoutASink()
    {
        Log.UseSink(newSink: null);
        Log.Write(line: $"nothing listens {42}");
        Log.Write(error: new InvalidOperationException(), context: $"nor here");
    }

    static InvalidOperationException Thrown(string message)
    {
        try
        {
            throw new InvalidOperationException(message: message);
        }
        catch (InvalidOperationException error)
        {
            return error;
        }
    }
}
