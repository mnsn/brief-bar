using System.Globalization;

namespace BriefBar.Core;

/// What a section counts, for sentences such as "3 pull requests".
public sealed record CountNoun(string One, string Many)
{
    /// "1 chat", "3 chats".
    public string Format(int count) =>
        string.Create(provider: CultureInfo.InvariantCulture, handler: $"{count} {(count == 1 ? One : Many)}");
}
