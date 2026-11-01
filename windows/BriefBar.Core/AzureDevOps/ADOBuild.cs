using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A pipeline run, from `{project}/_apis/build/builds`. Everything but its ID and pipeline is read leniently.
public sealed record ADOBuild(int Id, ADOBuildDefinitionRef Definition)
{
    public string? BuildNumber { get; init; }

    /// `notStarted`, `inProgress`, `completed`, `cancelling` or `postponed`.
    public string? Status { get; init; }

    /// `succeeded`, `partiallySucceeded`, `failed`, `canceled` or `none`.
    public string? Result { get; init; }

    /// `manual`, `individualCI`, `batchedCI`, `schedule`, `pullRequest`, `resourceTrigger`…
    public string? Reason { get; init; }

    public string? SourceBranch { get; init; }

    public DateTimeOffset? QueueTime { get; init; }

    public DateTimeOffset? StartTime { get; init; }

    public DateTimeOffset? FinishTime { get; init; }

    public ADOProjectRef? Project { get; init; }

    public ADOIdentity? RequestedFor { get; init; }

    /// The commit it built.
    public string? SourceVersion { get; init; }

    /// The run whose completion started it, for a pipeline-completion or resource trigger.
    public int? TriggeredByBuildId { get; init; }

    internal static ADOBuild? Read(JsonElement element)
    {
        if (ADOJson.WholeNumber(element: element, name: "id") is not { } id
            || ADOJson.Node(element: element, name: "definition") is not { } node || ADOBuildDefinitionRef.Read(element: node) is not { } definition)
        {
            return null;
        }
        return new ADOBuild(Id: id, Definition: definition)
        {
            BuildNumber = ADOJson.Text(element: element, name: "buildNumber"),
            Status = ADOJson.Text(element: element, name: "status"),
            Result = ADOJson.Text(element: element, name: "result"),
            Reason = ADOJson.Text(element: element, name: "reason"),
            SourceBranch = ADOJson.Text(element: element, name: "sourceBranch"),
            QueueTime = ADOJson.Date(element: element, name: "queueTime"),
            StartTime = ADOJson.Date(element: element, name: "startTime"),
            FinishTime = ADOJson.Date(element: element, name: "finishTime"),
            Project = ADOJson.Node(element: element, name: "project") is { } project ? ADOProjectRef.Read(element: project) : null,
            RequestedFor = ADOJson.Node(element: element, name: "requestedFor") is { } requester ? ADOIdentity.Read(element: requester) : null,
            SourceVersion = ADOJson.Text(element: element, name: "sourceVersion"),
            TriggeredByBuildId = ADOJson.WholeNumber(element: ADOJson.Node(element: element, name: "triggeredByBuild"), name: "id"),
        };
    }
}
