using System.Globalization;
using System.Text.RegularExpressions;

namespace BriefBar.Core;

/// Flattens markdown snippets, such as a Copilot session's preview or a pull request's comment, into one readable line.
/// The Mac's `PlainText`, which CopilotCore and AzureDevOpsCore each have a copy of.
public static partial class PlainText
{
    /// Its words, one space apart, on one line.
    public static string SingleLine(string text)
    {
        ArgumentNullException.ThrowIfNull(argument: text);
        return string.Join(separator: ' ', value: text.Split(separator: (char[]?)null, options: StringSplitOptions.RemoveEmptyEntries));
    }

    /// Its first `length` characters as people see them, as Swift's `prefix` counts them: one made of several, such as an
    /// emoji, isn't cut in two.
    public static string Prefix(string text, int length)
    {
        ArgumentNullException.ThrowIfNull(argument: text);
        ArgumentOutOfRangeException.ThrowIfNegative(value: length);
        var characters = new StringInfo(value: text);
        return characters.LengthInTextElements <= length ? text : characters.SubstringByTextElements(startingTextElement: 0, lengthInTextElements: length);
    }

    public static string FromMarkdown(string markdown)
    {
        ArgumentNullException.ThrowIfNull(argument: markdown);
        // Links, including one cut off by the app's preview truncation.
        var text = Link().Replace(input: markdown, evaluator: match => match.Groups[1].Value);
        text = Emphasis().Replace(input: text, replacement: string.Empty);
        text = LineMarker().Replace(input: text, replacement: string.Empty);
        return SingleLine(text: text);
    }

    [GeneratedRegex(pattern: @"!?\[([^\]]*)\]\([^)]*(\)|$)", options: RegexOptions.CultureInvariant)]
    private static partial Regex Link();

    [GeneratedRegex(pattern: @"(\*\*|__|`)", options: RegexOptions.CultureInvariant)]
    private static partial Regex Emphasis();

    [GeneratedRegex(pattern: @"^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+)", options: RegexOptions.CultureInvariant | RegexOptions.Multiline)]
    private static partial Regex LineMarker();
}
