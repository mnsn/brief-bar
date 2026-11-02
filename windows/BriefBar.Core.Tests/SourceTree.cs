namespace BriefBar.Core.Tests;

/// windows/'s own C# code, for the tests that check it.
internal static class SourceTree
{
    /// Every C# file in windows/, relative to it, with forward slashes, except build output and these tests.
    public static List<string> Files()
    {
        var root = Folder();
        return Directory.EnumerateFiles(path: root, searchPattern: "*.cs", searchOption: SearchOption.AllDirectories)
            .Select(selector: path => Path.GetRelativePath(relativeTo: root, path: path).Replace(oldChar: '\\', newChar: '/'))
            .Where(predicate: path => !path.Contains(value: "/bin/", comparisonType: StringComparison.Ordinal)
                && !path.Contains(value: "/obj/", comparisonType: StringComparison.Ordinal)
                && !path.StartsWith(value: "BriefBar.Core.Tests/", comparisonType: StringComparison.Ordinal))
            .ToList();
    }

    /// The text of `file`, relative to windows/.
    public static string Read(string file) => File.ReadAllText(path: Path.Combine(path1: Folder(), path2: file));

    /// windows/, found from where the tests run.
    static string Folder()
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
