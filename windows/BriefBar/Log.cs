namespace BriefBar;

/// What BriefBar did, in %TEMP%\BriefBar.log, for checking it: states and window events, never content.
internal static class Log
{
    static readonly string path = Path.Combine(Path.GetTempPath(), "BriefBar.log");

    public static void Write(string message)
    {
        try
        {
            File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} {message}{Environment.NewLine}");
        }
        catch (IOException)
        {
        }
    }
}
