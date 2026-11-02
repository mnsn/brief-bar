namespace BriefBar.Core.Teams;

/// Teams' message types: which are what someone wrote, and which are events in the chat, such as a call, a recording or
/// someone joining.
public static class TeamsMessageTypes
{
    /// Text, and rich text, including cards and files, except what calls and meetings post: their logs, recordings and
    /// transcripts. Not events (`Event/…`) or changes to the chat (`ThreadActivity/…`).
    public static bool IsContent(string? type)
    {
        if (string.IsNullOrEmpty(value: type))
        {
            return false;
        }
        if (type.StartsWith(value: "RichText/Media_Call", comparisonType: StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        return string.Equals(a: type, b: "Text", comparisonType: StringComparison.OrdinalIgnoreCase)
            || string.Equals(a: type, b: "RichText", comparisonType: StringComparison.OrdinalIgnoreCase)
            || type.StartsWith(value: "RichText/", comparisonType: StringComparison.OrdinalIgnoreCase);
    }
}
