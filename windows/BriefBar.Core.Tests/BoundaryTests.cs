using System.Text.RegularExpressions;

namespace BriefBar.Core.Tests;

/// The ground rules' boundaries, as `make check-boundaries` checks them on the Mac: only Azure DevOps and GitHub use the
/// network, each in its own folder of BriefBar.Core, and only `ProcessRunner` starts programs.
public sealed partial class BoundaryTests
{
    /// Where networking may be used, relative to windows/.
    static readonly string[] networking = ["BriefBar.Core/AzureDevOps/", "BriefBar.Core/GitHub/"];

    /// Where programs may be started.
    static readonly string[] processes = ["BriefBar.Core/ProcessRunner.cs"];

    [GeneratedRegex(pattern: @"\b(HttpClient|HttpMessageHandler|SocketsHttpHandler|HttpWebRequest|WebRequest|WebClient|TcpClient|UdpClient|Socket|ClientWebSocket|System\.Net\.Http|System\.Net\.Sockets|Windows\.Web\.Http)\b")]
    private static partial Regex NetworkingApi();

    [GeneratedRegex(pattern: @"\b(Process\.Start|ProcessStartInfo|System\.Diagnostics\.Process\b|CreateProcess|ShellExecute|WinExec)\b")]
    private static partial Regex ProcessApi();

    [Fact]
    public void OnlyAzureDevOpsAndGitHubUseTheNetwork()
    {
        Assert.Empty(collection: Uses(api: NetworkingApi(), allowed: networking));
    }

    [Fact]
    public void OnlyProcessRunnerStartsPrograms()
    {
        Assert.Empty(collection: Uses(api: ProcessApi(), allowed: processes));
    }

    [Fact]
    public void FindsTheCode()
    {
        // Guards the two tests above against passing because they read nothing.
        Assert.Contains(collection: SourceFiles(), filter: file => file.EndsWith(value: "BriefBar.Core/ItemState.cs", comparisonType: StringComparison.Ordinal));
        Assert.Contains(collection: SourceFiles(), filter: file => file.EndsWith(value: "BriefBar/App.xaml.cs", comparisonType: StringComparison.Ordinal));
    }

    /// The files outside `allowed` that use `api`, with what they use.
    static List<string> Uses(Regex api, string[] allowed) => SourceFiles()
        .Where(predicate: file => !allowed.Any(predicate: place => file.StartsWith(value: place, comparisonType: StringComparison.Ordinal)))
        .SelectMany(selector: file => api.Matches(input: File.ReadAllText(path: Path.Combine(path1: WindowsFolder(), path2: file)))
            .Select(selector: match => file + ": " + match.Value))
        .ToList();

    /// Every C# file in windows/, relative to it, with forward slashes, except build output and these tests.
    static List<string> SourceFiles()
    {
        var root = WindowsFolder();
        return Directory.EnumerateFiles(path: root, searchPattern: "*.cs", searchOption: SearchOption.AllDirectories)
            .Select(selector: path => Path.GetRelativePath(relativeTo: root, path: path).Replace(oldChar: '\\', newChar: '/'))
            .Where(predicate: path => !path.Contains(value: "/bin/", comparisonType: StringComparison.Ordinal)
                && !path.Contains(value: "/obj/", comparisonType: StringComparison.Ordinal)
                && !path.StartsWith(value: "BriefBar.Core.Tests/", comparisonType: StringComparison.Ordinal))
            .ToList();
    }

    /// windows/, found from where the tests run.
    static string WindowsFolder()
    {
        for (var folder = new DirectoryInfo(path: AppContext.BaseDirectory); folder is not null; folder = folder.Parent)
        {
            if (File.Exists(path: Path.Combine(path1: folder.FullName, path2: "BriefBar.Windows.slnx")))
            {
                return folder.FullName;
            }
        }
        throw new InvalidOperationException(message: "The tests run outside windows/, so they can't read its code.");
    }
}
