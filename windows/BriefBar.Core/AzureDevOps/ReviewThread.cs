namespace BriefBar.Core.AzureDevOps;

/// A conversation on a pull request, general or on a line of code: its comments by people, in order. The Mac's
/// `ReviewThread`.
public sealed record ReviewThread(int Id, ValueList<ReviewComment> Comments, string? Status = "active", string? FilePath = null, int? Line = null)
{
    /// Resolved one way or another: fixed, won't fix, closed or by design.
    public bool IsResolved => Status is not (null or "active" or "pending" or "unknown");

    /// "Program.cs", for a thread on a line of code.
    public string? FileName => FilePath is null ? null : FilePath[(FilePath.LastIndexOf(value: '/') + 1)..];

    /// The conversation in `thread`, its names from `names` and its own identities; null when nothing is left once system
    /// and deleted comments are left out.
    public static ReviewThread? From(ADOThread thread, IReadOnlyDictionary<string, string> names)
    {
        ArgumentNullException.ThrowIfNull(argument: thread);
        ArgumentNullException.ThrowIfNull(argument: names);
        var known = new Dictionary<string, string>(collection: names, comparer: StringComparer.Ordinal);
        foreach (var identity in (thread.Identities ?? new Dictionary<string, ADOIdentity>()).Values)
        {
            Name(names: known, id: identity.Id, name: identity.DisplayName);
        }
        foreach (var comment in thread.Comments ?? [])
        {
            if (comment.Author is { } author)
            {
                Name(names: known, id: author.Id, name: author.DisplayName);
            }
        }
        var comments = new List<ReviewComment>();
        foreach (var comment in thread.Comments ?? [])
        {
            if (comment.IsDeleted == true || comment.CommentType == "system" || comment.Author is not { } author
                || comment.Content is not { Length: > 0 } content)
            {
                continue;
            }
            comments.Add(item: new ReviewComment(
                id: comment.Id,
                author: Person.From(identity: author),
                text: CommentText.Plain(markdown: content, names: known),
                publishedAt: comment.PublishedDate ?? thread.PublishedDate ?? DateTimeOffset.MinValue,
                mentions: CommentText.MentionedIds(markdown: content)));
        }
        if (comments.Count == 0)
        {
            return null;
        }
        return new ReviewThread(
            Id: thread.Id,
            Comments: new ValueList<ReviewComment>(items: comments.OrderBy(keySelector: comment => comment.PublishedAt)),
            Status: thread.Status,
            FilePath: thread.ThreadContext?.FilePath,
            Line: thread.ThreadContext?.RightFileStartLine ?? thread.ThreadContext?.LeftFileStartLine);
    }

    /// Names `id` as `name`, or forgets its name when there's none, as the Mac's dictionary does when it's given nil.
    static void Name(Dictionary<string, string> names, string id, string? name)
    {
        var key = id.ToLowerInvariant();
        if (name is null)
        {
            names.Remove(key: key);
        }
        else
        {
            names[key] = name;
        }
    }
}
