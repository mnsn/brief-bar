namespace BriefBar.Core.AzureDevOps;

/// One run of a pipeline. The Mac's `PipelineRun`.
public sealed record PipelineRun
{
    public required int Id { get; init; }

    public required string Organization { get; init; }

    public required string ProjectName { get; init; }

    /// Its build number, such as `20261021.4`.
    public required string Number { get; init; }

    public required PipelineRunStatus Status { get; init; }

    public required PipelineTrigger Trigger { get; init; }

    /// The branch, such as `main`, or `!123` for a pull request.
    public required string Branch { get; init; }

    /// Who started it, or whose push or pull request did; none for a service.
    public string? RequestedFor { get; init; }

    public DateTimeOffset? QueuedAt { get; init; }

    public DateTimeOffset? StartedAt { get; init; }

    public DateTimeOffset? FinishedAt { get; init; }

    /// It ended, one way or another.
    public bool IsFinished => Status is not (PipelineRunStatus.Queued or PipelineRunStatus.Running);

    /// When it last changed: finished, started or queued.
    public DateTimeOffset? ChangedAt => FinishedAt ?? StartedAt ?? QueuedAt;

    /// Its page in Azure DevOps.
    public Uri WebUrl => ADOEndpoint.BuildPage(organization: Organization, project: ProjectName, buildId: Id);

    /// The run `dto` describes, in `organization`; in `projectName` unless it says its own project.
    public static PipelineRun From(string organization, string projectName, ADOBuild dto)
    {
        ArgumentNullException.ThrowIfNull(argument: dto);
        var requester = dto.RequestedFor is { } identity ? Person.From(identity: identity) : null;
        return new PipelineRun
        {
            Id = dto.Id,
            Organization = organization,
            ProjectName = dto.Project?.Name ?? projectName,
            Number = dto.BuildNumber ?? dto.Id.ToString(provider: System.Globalization.CultureInfo.InvariantCulture),
            Status = StatusOf(status: dto.Status, result: dto.Result),
            Trigger = TriggerOf(reason: dto.Reason),
            Branch = BranchOf(reference: dto.SourceBranch),
            RequestedFor = requester is null || IsService(person: requester) ? null : requester.Name,
            QueuedAt = dto.QueueTime,
            StartedAt = dto.StartTime,
            FinishedAt = dto.FinishTime,
        };
    }

    /// `main` for `refs/heads/main`, `!123` for `refs/pull/123/merge`, and a tag's name for its ref.
    public static string BranchOf(string? reference)
    {
        if (reference is null)
        {
            return string.Empty;
        }
        if (reference.StartsWith(value: "refs/heads/", comparisonType: StringComparison.Ordinal))
        {
            return reference["refs/heads/".Length..];
        }
        var parts = reference.Split(separator: '/', options: StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length >= 3 && parts[0] == "refs" && parts[1] == "pull")
        {
            return "!" + parts[2];
        }
        return reference.StartsWith(value: "refs/tags/", comparisonType: StringComparison.Ordinal) ? reference["refs/tags/".Length..] : reference;
    }

    /// Azure DevOps itself, a build service or a bot, rather than someone: scheduled runs are requested by
    /// `Microsoft.VisualStudio.Services.TFS`.
    internal static bool IsService(Person person)
    {
        var name = person.Name;
        return person.IsBot
            || name.StartsWith(value: "Microsoft.VisualStudio.", comparisonType: StringComparison.Ordinal)
            || name.StartsWith(value: "Project Collection ", comparisonType: StringComparison.Ordinal)
            || (!name.Contains(value: ' ', comparisonType: StringComparison.Ordinal) && name.Contains(value: '.', comparisonType: StringComparison.Ordinal));
    }

    static PipelineRunStatus StatusOf(string? status, string? result) => status switch
    {
        "completed" => result switch
        {
            "succeeded" => PipelineRunStatus.Succeeded,
            "partiallySucceeded" => PipelineRunStatus.PartiallySucceeded,
            "failed" => PipelineRunStatus.Failed,
            _ => PipelineRunStatus.Canceled,
        },
        "inProgress" or "cancelling" => PipelineRunStatus.Running,
        _ => PipelineRunStatus.Queued,
    };

    static PipelineTrigger TriggerOf(string? reason) => reason switch
    {
        "manual" or "userCreated" => PipelineTrigger.Manual,
        "individualCI" or "batchedCI" => PipelineTrigger.Push,
        "pullRequest" or "validateShelveset" => PipelineTrigger.PullRequest,
        "schedule" => PipelineTrigger.Schedule,
        "buildCompletion" or "resourceTrigger" or "triggered" => PipelineTrigger.Pipeline,
        _ => PipelineTrigger.Other,
    };
}
