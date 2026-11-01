using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A comment thread on a pull request. Activity, such as pushes, votes and reviewer changes, comes as system threads whose
/// `CodeReviewThreadType` property says what happened.
public sealed record ADOThread(int Id)
{
    public DateTimeOffset? PublishedDate { get; init; }

    public DateTimeOffset? LastUpdatedDate { get; init; }

    /// `active`, `fixed`, `wontFix`, `closed`, `byDesign`, `pending` or `unknown`.
    public string? Status { get; init; }

    public bool? IsDeleted { get; init; }

    public ADOThreadContext? ThreadContext { get; init; }

    public IReadOnlyList<ADOComment>? Comments { get; init; }

    public IReadOnlyDictionary<string, ADOProperty>? Properties { get; init; }

    /// Identities that the properties refer to by key, such as who voted.
    public IReadOnlyDictionary<string, ADOIdentity>? Identities { get; init; }

    /// The kind of activity a system thread records, such as `VoteUpdate` or `RefUpdate`.
    public string? ActivityType => Property(name: "CodeReviewThreadType");

    /// The property `name`'s value.
    public string? Property(string name) =>
        Properties is not null && Properties.TryGetValue(key: name, value: out var property) ? property.Value : null;

    /// The identity the property `name` refers to.
    public ADOIdentity? Identity(string name) =>
        Property(name: name) is { } key && Identities is not null && Identities.TryGetValue(key: key, value: out var identity) ? identity : null;

    internal static ADOThread? Read(JsonElement element) =>
        LenientJson.WholeNumber(element: element, name: "id") is { } id
            ? new ADOThread(Id: id)
            {
                PublishedDate = LenientJson.Date(element: element, name: "publishedDate"),
                LastUpdatedDate = LenientJson.Date(element: element, name: "lastUpdatedDate"),
                Status = LenientJson.Text(element: element, name: "status"),
                IsDeleted = LenientJson.Flag(element: element, name: "isDeleted"),
                ThreadContext = LenientJson.Node(element: element, name: "threadContext") is { } context ? ADOThreadContext.Read(element: context) : null,
                Comments = LenientJson.Items(element: element, name: "comments", read: ADOComment.Read),
                Properties = LenientJson.Members(element: element, name: "properties", read: ADOProperty.Read),
                Identities = LenientJson.Members(element: element, name: "identities", read: ADOIdentity.Read),
            }
            : null;
}
