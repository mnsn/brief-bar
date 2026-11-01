using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// One record in a run's timeline: a stage, phase, job, task or checkpoint.
public sealed record ADOTimelineRecord(string Id)
{
    public string? ParentId { get; init; }

    /// `Stage`, `Phase`, `Job`, `Task` or `Checkpoint`.
    public string? Type { get; init; }

    public string? Name { get; init; }

    public string? Identifier { get; init; }

    public int? Order { get; init; }

    /// `pending`, `inProgress` or `completed`.
    public string? State { get; init; }

    /// `succeeded`, `succeededWithIssues`, `failed`, `canceled`, `skipped` or `abandoned`.
    public string? Result { get; init; }

    public DateTimeOffset? StartTime { get; init; }

    public DateTimeOffset? FinishTime { get; init; }

    public IReadOnlyList<ADOTimelineIssue>? Issues { get; init; }

    internal static ADOTimelineRecord? Read(JsonElement element) =>
        LenientJson.Text(element: element, name: "id") is { } id
            ? new ADOTimelineRecord(Id: id)
            {
                ParentId = LenientJson.Text(element: element, name: "parentId"),
                Type = LenientJson.Text(element: element, name: "type"),
                Name = LenientJson.Text(element: element, name: "name"),
                Identifier = LenientJson.Text(element: element, name: "identifier"),
                Order = LenientJson.WholeNumber(element: element, name: "order"),
                State = LenientJson.Text(element: element, name: "state"),
                Result = LenientJson.Text(element: element, name: "result"),
                StartTime = LenientJson.Date(element: element, name: "startTime"),
                FinishTime = LenientJson.Date(element: element, name: "finishTime"),
                Issues = LenientJson.Items(element: element, name: "issues", read: ADOTimelineIssue.Read),
            }
            : null;
}
