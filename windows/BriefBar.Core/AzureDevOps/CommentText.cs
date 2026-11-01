using System.Globalization;
using System.Text.RegularExpressions;

namespace BriefBar.Core.AzureDevOps;

/// Turns a comment's markdown into one plain line for its row. The Mac's `CommentText`.
public static partial class CommentText
{
    /// The lowercased IDs of the people `markdown` @mentions, which it writes as `@<6B3C1F2A-…>`.
    public static IReadOnlyList<string> MentionedIds(string markdown)
    {
        ArgumentNullException.ThrowIfNull(argument: markdown);
        return Mention().Matches(input: markdown).Select(selector: match => match.Groups[1].Value.ToLowerInvariant()).ToList();
    }

    /// `markdown` as one plain line, at most `limit` characters: mentions as names from `names`, code fences and HTML tags
    /// gone, with the text inside, and entities decoded.
    public static string Plain(string markdown, IReadOnlyDictionary<string, string> names, int limit = 500)
    {
        ArgumentNullException.ThrowIfNull(argument: markdown);
        ArgumentNullException.ThrowIfNull(argument: names);
        var text = Mention().Replace(
            input: markdown,
            evaluator: match => "@" + (names.TryGetValue(key: match.Groups[1].Value.ToLowerInvariant(), value: out var name) ? name : "someone"));
        text = CodeFence().Replace(input: text, replacement: " ");
        text = Tag().Replace(input: text, replacement: " ");
        foreach (var (entity, character) in new[] { ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&") })
        {
            text = text.Replace(oldValue: entity, newValue: character, comparisonType: StringComparison.Ordinal);
        }
        text = PlainText.FromMarkdown(markdown: text);
        var info = new StringInfo(value: text);
        return info.LengthInTextElements <= limit
            ? text
            : info.SubstringByTextElements(startingTextElement: 0, lengthInTextElements: limit - 1).Trim() + "…";
    }

    [GeneratedRegex(pattern: "@<([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})>", options: RegexOptions.CultureInvariant)]
    private static partial Regex Mention();

    [GeneratedRegex(pattern: @"^\s*```.*$", options: RegexOptions.CultureInvariant | RegexOptions.Multiline)]
    private static partial Regex CodeFence();

    [GeneratedRegex(pattern: "<[^>]{1,200}>", options: RegexOptions.CultureInvariant)]
    private static partial Regex Tag();
}
