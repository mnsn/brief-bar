using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// Where a thread is in the code: its file, and its line on the right side of the diff, or on the left.
public sealed record ADOThreadContext(string? FilePath, int? RightFileStartLine = null, int? LeftFileStartLine = null)
{
    internal static ADOThreadContext Read(JsonElement element) => new(
        FilePath: LenientJson.Text(element: element, name: "filePath"),
        RightFileStartLine: LenientJson.WholeNumber(element: LenientJson.Node(element: element, name: "rightFileStart"), name: "line"),
        LeftFileStartLine: LenientJson.WholeNumber(element: LenientJson.Node(element: element, name: "leftFileStart"), name: "line"));
}
