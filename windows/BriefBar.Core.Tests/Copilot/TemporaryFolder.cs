namespace BriefBar.Core.Tests.Copilot;

/// A folder of its own for a test, deleted with what's in it once the test is done.
internal sealed class TemporaryFolder : IDisposable
{
    public TemporaryFolder()
    {
        Path = System.IO.Path.Combine(path1: System.IO.Path.GetTempPath(), path2: "BriefBarCopilotTests-" + Guid.NewGuid().ToString(format: "N"));
        Directory.CreateDirectory(path: Path);
    }

    public string Path { get; }

    public string Combine(params string[] parts) => System.IO.Path.Combine(paths: [Path, .. parts]);

    public void Dispose()
    {
        // A file a test just closed can stay locked for a moment while Windows lets go of it.
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                if (Directory.Exists(path: Path))
                {
                    Directory.Delete(path: Path, recursive: true);
                }
                return;
            }
            catch (IOException) when (attempt < 19)
            {
                Thread.Sleep(millisecondsTimeout: 100);
            }
            catch (UnauthorizedAccessException) when (attempt < 19)
            {
                Thread.Sleep(millisecondsTimeout: 100);
            }
        }
    }
}
