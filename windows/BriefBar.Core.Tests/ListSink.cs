using BriefBar.Core.Logging;

namespace BriefBar.Core.Tests;

/// A log sink that keeps its lines, for tests to read.
internal sealed class ListSink : ILogSink
{
    readonly List<string> lines = [];

    public IReadOnlyList<string> Lines
    {
        get
        {
            lock (lines)
            {
                return [.. lines];
            }
        }
    }

    public void Write(string line)
    {
        lock (lines)
        {
            lines.Add(item: line);
        }
    }
}
