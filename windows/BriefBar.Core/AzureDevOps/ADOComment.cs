using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A comment in a thread.
public sealed record ADOComment(int Id)
{
    public int? ParentCommentId { get; init; }

    public ADOIdentity? Author { get; init; }

    public string? Content { get; init; }

    public DateTimeOffset? PublishedDate { get; init; }

    /// `text`, `system` or `codeChange`.
    public string? CommentType { get; init; }

    public bool? IsDeleted { get; init; }

    internal static ADOComment? Read(JsonElement element) =>
        ADOJson.WholeNumber(element: element, name: "id") is { } id
            ? new ADOComment(Id: id)
            {
                ParentCommentId = ADOJson.WholeNumber(element: element, name: "parentCommentId"),
                Author = ADOJson.Node(element: element, name: "author") is { } author ? ADOIdentity.Read(element: author) : null,
                Content = ADOJson.Text(element: element, name: "content"),
                PublishedDate = ADOJson.Date(element: element, name: "publishedDate"),
                CommentType = ADOJson.Text(element: element, name: "commentType"),
                IsDeleted = ADOJson.Flag(element: element, name: "isDeleted"),
            }
            : null;
}
