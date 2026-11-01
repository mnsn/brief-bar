using System.Globalization;

namespace BriefBar.Core.AzureDevOps;

/// A pull request, as the lists say it is. The Mac's `PullRequest`.
public sealed record PullRequest
{
    public required PRKey Key { get; init; }

    public required string Title { get; init; }

    public PullRequestStatus Status { get; init; } = PullRequestStatus.Active;

    public required Person Author { get; init; }

    public required DateTimeOffset CreatedAt { get; init; }

    public DateTimeOffset? ClosedAt { get; init; }

    public required string ProjectId { get; init; }

    public required string ProjectName { get; init; }

    public required string RepositoryId { get; init; }

    public required string RepositoryName { get; init; }

    public string SourceBranch { get; init; } = "feature";

    public string TargetBranch { get; init; } = "main";

    public bool IsDraft { get; init; }

    public string? MergeStatus { get; init; } = "succeeded";

    public ValueList<Reviewer> Reviewers { get; init; } = [];

    public bool AutoComplete { get; init; }

    public string? SourceCommit { get; init; }

    public string? TargetCommit { get; init; }

    /// The synthetic validation merge while it's active; once it's completed, the commit that merged it into its target
    /// branch.
    public string? MergeCommit { get; init; }

    public bool HasConflicts => MergeStatus == "conflicts";

    public Uri WebUrl => ADOEndpoint.PullRequestPage(organization: Key.Organization, project: ProjectName, repository: RepositoryName, id: Key.Number);

    /// Changes whenever something the list reports changes, so that its details are read again.
    public string Fingerprint
    {
        get
        {
            var votes = Reviewers
                .Select(selector: reviewer => reviewer.Person.Id + "=" + ((int)reviewer.Vote).ToString(provider: CultureInfo.InvariantCulture) + (reviewer.HasDeclined ? "d" : string.Empty))
                .Order(comparer: StringComparer.Ordinal);
            return string.Join(separator: '|', values: [
                Title,
                RawValue(status: Status),
                IsDraft ? "draft" : string.Empty,
                MergeStatus ?? string.Empty,
                AutoComplete ? "auto" : string.Empty,
                SourceCommit ?? string.Empty,
                TargetCommit ?? string.Empty,
                string.Join(separator: ',', values: votes),
            ]);
        }
    }

    /// The pull request `dto` describes, in `organization`.
    public static PullRequest From(string organization, ADOPullRequest dto)
    {
        ArgumentNullException.ThrowIfNull(argument: dto);
        return new PullRequest
        {
            Key = new PRKey(Organization: organization, Number: dto.PullRequestId),
            Title = PlainText.SingleLine(text: dto.Title),
            Status = dto.Status switch
            {
                "active" => PullRequestStatus.Active,
                "completed" => PullRequestStatus.Completed,
                "abandoned" => PullRequestStatus.Abandoned,
                _ => PullRequestStatus.Other,
            },
            Author = Person.From(identity: dto.CreatedBy),
            CreatedAt = dto.CreationDate,
            ClosedAt = dto.ClosedDate,
            ProjectId = dto.Repository.Project.Id,
            ProjectName = dto.Repository.Project.Name,
            RepositoryId = dto.Repository.Id,
            RepositoryName = dto.Repository.Name,
            SourceBranch = BranchName(reference: dto.SourceRefName),
            TargetBranch = BranchName(reference: dto.TargetRefName),
            IsDraft = dto.IsDraft ?? false,
            MergeStatus = dto.MergeStatus,
            Reviewers = new ValueList<Reviewer>(items: (dto.Reviewers ?? []).Select(selector: reviewer => new Reviewer(
                Person: Person.From(identity: new ADOIdentity(Id: reviewer.Id, DisplayName: reviewer.DisplayName, UniqueName: reviewer.UniqueName, IsContainer: reviewer.IsContainer)),
                Vote: Votes.From(raw: reviewer.Vote),
                IsRequired: reviewer.IsRequired ?? false,
                IsGroup: reviewer.IsContainer ?? false,
                HasDeclined: reviewer.HasDeclined ?? false))),
            AutoComplete = dto.AutoCompleteSetBy is not null,
            SourceCommit = dto.LastMergeSourceCommit,
            TargetCommit = dto.LastMergeTargetCommit,
            MergeCommit = dto.LastMergeCommit,
        };
    }

    /// `main` from `refs/heads/main`.
    public static string BranchName(string? reference)
    {
        const string Heads = "refs/heads/";
        if (reference is null)
        {
            return string.Empty;
        }
        return reference.StartsWith(value: Heads, comparisonType: StringComparison.Ordinal) ? reference[Heads.Length..] : reference;
    }

    /// `active`, `completed`, `abandoned` or `other`.
    public static string RawValue(PullRequestStatus status) => status switch
    {
        PullRequestStatus.Active => "active",
        PullRequestStatus.Completed => "completed",
        PullRequestStatus.Abandoned => "abandoned",
        PullRequestStatus.Other => "other",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(status), actualValue: status, message: "Not a status."),
    };

    /// Opens the pull request at one comment thread.
    public Uri ThreadUrl(int threadId) =>
        ADOEndpoint.PullRequestPage(organization: Key.Organization, project: ProjectName, repository: RepositoryName, id: Key.Number, threadId: threadId);

    /// The reviewer whose ID is `id`, in any case. The Mac's `reviewer(_:)`.
    public Reviewer? FindReviewer(string id)
    {
        ArgumentNullException.ThrowIfNull(argument: id);
        var lowered = id.ToLowerInvariant();
        return Reviewers.FirstOrDefault(predicate: reviewer => reviewer.Person.Id == lowered);
    }
}
