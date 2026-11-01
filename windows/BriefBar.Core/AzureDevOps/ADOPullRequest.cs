using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A pull request, as `_apis/git/pullrequests` lists it. What it may leave out is optional; one without its number,
/// title, status, author, creation date or repository can't be read. The Mac's `ADOPullRequest`, with each commit's ID in
/// place of its `ADOCommitRef`.
public sealed record ADOPullRequest(
    int PullRequestId,
    string Title,
    string Status,
    ADOIdentity CreatedBy,
    DateTimeOffset CreationDate,
    ADORepositoryRef Repository)
{
    public DateTimeOffset? ClosedDate { get; init; }

    public string? SourceRefName { get; init; }

    public string? TargetRefName { get; init; }

    /// `succeeded`, `conflicts`, `queued`, `rejectedByPolicy`, `failure` or `notSet`.
    public string? MergeStatus { get; init; }

    public bool? IsDraft { get; init; }

    public IReadOnlyList<ADOReviewer>? Reviewers { get; init; }

    public string? LastMergeSourceCommit { get; init; }

    public string? LastMergeTargetCommit { get; init; }

    /// The commit that merged it into its target branch, once it's completed.
    public string? LastMergeCommit { get; init; }

    public ADOIdentity? AutoCompleteSetBy { get; init; }

    internal static ADOPullRequest? Read(JsonElement element)
    {
        if (LenientJson.WholeNumber(element: element, name: "pullRequestId") is not { } id
            || LenientJson.Text(element: element, name: "title") is not { } title
            || LenientJson.Text(element: element, name: "status") is not { } status
            || LenientJson.Node(element: element, name: "createdBy") is not { } creator || ADOIdentity.Read(element: creator) is not { } createdBy
            || LenientJson.Date(element: element, name: "creationDate") is not { } created
            || LenientJson.Node(element: element, name: "repository") is not { } repositoryNode
            || ADORepositoryRef.Read(element: repositoryNode) is not { } repository)
        {
            return null;
        }
        return new ADOPullRequest(PullRequestId: id, Title: title, Status: status, CreatedBy: createdBy, CreationDate: created, Repository: repository)
        {
            ClosedDate = LenientJson.Date(element: element, name: "closedDate"),
            SourceRefName = LenientJson.Text(element: element, name: "sourceRefName"),
            TargetRefName = LenientJson.Text(element: element, name: "targetRefName"),
            MergeStatus = LenientJson.Text(element: element, name: "mergeStatus"),
            IsDraft = LenientJson.Flag(element: element, name: "isDraft"),
            Reviewers = LenientJson.Items(element: element, name: "reviewers", read: ADOReviewer.Read),
            LastMergeSourceCommit = Commit(element: element, name: "lastMergeSourceCommit"),
            LastMergeTargetCommit = Commit(element: element, name: "lastMergeTargetCommit"),
            LastMergeCommit = Commit(element: element, name: "lastMergeCommit"),
            AutoCompleteSetBy = LenientJson.Node(element: element, name: "autoCompleteSetBy") is { } setBy ? ADOIdentity.Read(element: setBy) : null,
        };
    }

    static string? Commit(JsonElement element, string name) =>
        LenientJson.Text(element: LenientJson.Node(element: element, name: name), name: "commitId");
}
