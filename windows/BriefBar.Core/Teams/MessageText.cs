using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;

namespace BriefBar.Core.Teams;

/// A Teams message's HTML as one plain line: tags gone, keeping the text inside them, such as a mention's name; an
/// emoji's own character; entities decoded.
public static partial class MessageText
{
    /// The longest text kept of a message, in characters as people see them.
    public const int Limit = 600;

    public static string Plain(string? html, int limit = Limit)
    {
        if (string.IsNullOrEmpty(value: html))
        {
            return string.Empty;
        }
        // An emoji is an element whose `alt` is the emoji itself, with nothing inside.
        var text = Emoji().Replace(input: html, evaluator: match => " " + WebUtility.HtmlDecode(value: match.Groups["alt"].Value) + " ");
        text = Break().Replace(input: text, replacement: " ");
        text = Tag().Replace(input: text, replacement: string.Empty);
        text = PlainText.SingleLine(text: WebUtility.HtmlDecode(value: text));
        var info = new StringInfo(value: text);
        return info.LengthInTextElements <= limit
            ? text
            : info.SubstringByTextElements(startingTextElement: 0, lengthInTextElements: limit - 1).TrimEnd() + "…";
    }

    [GeneratedRegex(pattern: @"<emoji\b[^>]*\balt=""(?<alt>[^""]*)""[^>]*>(\s*</emoji>)?", options: RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex Emoji();

    /// Where lines and blocks end, which become spaces, so words on either side don't run together.
    [GeneratedRegex(pattern: @"<(br|/p|/div|/li|/h[1-6]|/tr|/blockquote)\b[^>]*>", options: RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex Break();

    [GeneratedRegex(pattern: "<[^>]*>", options: RegexOptions.CultureInvariant)]
    private static partial Regex Tag();
}
