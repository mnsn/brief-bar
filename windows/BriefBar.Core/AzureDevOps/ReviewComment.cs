namespace BriefBar.Core.AzureDevOps;

/// A comment in a conversation on a pull request: plain text, with the people it @mentions by their lowercased IDs.
public sealed record ReviewComment
{
    public ReviewComment(int id, Person author, string text, DateTimeOffset publishedAt, IEnumerable<string>? mentions = null)
    {
        ArgumentNullException.ThrowIfNull(argument: author);
        ArgumentNullException.ThrowIfNull(argument: text);
        Id = id;
        Author = author;
        Text = text;
        PublishedAt = publishedAt;
        Mentions = new ValueList<string>(items: (mentions ?? []).Select(selector: mention => mention.ToLowerInvariant()));
    }

    public int Id { get; }

    public Person Author { get; }

    /// Plain text: markdown and HTML removed, mentions shown as names.
    public string Text { get; }

    public DateTimeOffset PublishedAt { get; }

    /// The lowercased IDs of the people it @mentions.
    public ValueList<string> Mentions { get; }
}
