namespace BriefBar.Core.Logging;

/// Where log lines go: a file for the app, a list for tests.
public interface ILogSink
{
    void Write(string line);
}
