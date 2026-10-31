using System.Globalization;
using System.Text;

namespace BriefBar.Core.Presentation;

/// What Narrator says for a row: everything it shows, in words, as the Mac's VoiceOver label and value do.
public static class RowWords
{
    /// "GitHub Copilot sessions: Release 2.4.0, Needs permission, acme-api, git push origin main, 1 minute ago": its
    /// source first, for the Overview, which mixes sources (`sourceName`), then its title, where it stands, what it's
    /// about, its links, unread messages, whether it's new, and when.
    public static string SpokenName(ItemRow row, string? sourceName, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: row);
        var parts = new List<string> { row.Title };
        parts.AddRange(collection: row.Status.Split(separator: '·'));
        if (row.Detail is { } detail)
        {
            parts.Add(item: detail);
        }
        parts.AddRange(collection: row.Chips.Select(selector: chip => ChipWords(chip: chip)));
        if (row.Unread > 0)
        {
            parts.Add(item: row.Unread == 1
                ? "1 unread message"
                : string.Create(provider: CultureInfo.InvariantCulture, handler: $"{row.Unread} unread messages"));
        }
        if (row.IsNew)
        {
            parts.Add(item: "new");
        }
        parts.Add(item: Elapsed.Spoken(since: row.Date, now: now));
        var spoken = Joined(parts: parts);
        return string.IsNullOrEmpty(value: sourceName) ? spoken : sourceName + ": " + spoken;
    }

    /// Parts said one after another: a comma between them, or just a space after one that ends a sentence, so nothing
    /// is said twice, as "pass.." would be. Empty parts are left out.
    static string Joined(IEnumerable<string> parts)
    {
        var text = new StringBuilder();
        foreach (var part in parts.Select(selector: part => part.Trim().TrimEnd(trimChars: [',', ';', ':']).Trim()))
        {
            if (part.Length == 0)
            {
                continue;
            }
            if (text.Length > 0)
            {
                text.Append(value: EndsSentence(text: text) ? " " : ", ");
            }
            text.Append(value: part);
        }
        return text.ToString();
    }

    static bool EndsSentence(StringBuilder text) => text[^1] is '.' or '?' or '!' or '…';

    static string ChipWords(RowChip chip) => chip.Kind switch
    {
        RowChipKind.WorkItem => "work item " + chip.Text,
        RowChipKind.PullRequest => "pull request " + chip.Text,
        _ => chip.Text,
    };
}
