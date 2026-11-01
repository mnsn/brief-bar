using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// `{"count": n, "value": [...]}`, the envelope of every list Azure DevOps sends, without the elements that couldn't be
/// read. The Mac's `ADOList`.
public sealed record ADOList<T>(IReadOnlyList<T> Value, int Skipped)
    where T : class
{
    /// The list in `element`, each element read by `read`; null when it isn't a list.
    internal static ADOList<T>? Read(JsonElement element, Func<JsonElement, T?> read)
    {
        ArgumentNullException.ThrowIfNull(argument: read);
        if (ADOJson.Member(element: element, name: "value") is not { ValueKind: JsonValueKind.Array } array)
        {
            return null;
        }
        var items = new List<T>();
        var skipped = 0;
        foreach (var item in array.EnumerateArray())
        {
            if (read(arg: item) is { } value)
            {
                items.Add(item: value);
            }
            else
            {
                skipped++;
            }
        }
        return new ADOList<T>(Value: items, Skipped: skipped);
    }
}
