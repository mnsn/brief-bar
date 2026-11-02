using System.Globalization;

namespace BriefBar.Core.AzureDevOps;

/// Where a run failed first, and the first error there: its stage, when the pipeline has stages, the task or job that
/// failed, and its message. The Mac's `PipelineFailure`.
public sealed record PipelineFailure(string? Stage, string Step, string? Message)
{
    /// The step and its first error: "Run unit tests: 2 tests failed in CheckoutTests.", or "Run unit tests failed".
    public string Summary => Message is { } message ? Step + ": " + message : Step + " failed";

    /// The earliest failed task, or job, or stage when no task failed; null when nothing failed.
    public static PipelineFailure? First(ADOTimeline timeline)
    {
        ArgumentNullException.ThrowIfNull(argument: timeline);
        var records = timeline.Records;
        var byId = new Dictionary<string, ADOTimelineRecord>(comparer: StringComparer.Ordinal);
        foreach (var record in records)
        {
            byId.TryAdd(key: record.Id, value: record);
        }
        var failed = Earliest(records: records, type: "Task") ?? Earliest(records: records, type: "Job") ?? Earliest(records: records, type: "Stage");
        if (failed is null)
        {
            return null;
        }
        string? stage = null;
        var parent = failed.ParentId is { } parentId ? byId.GetValueOrDefault(key: parentId) : null;
        // Up to the run, so a stage within a stage names the outer one, as the Mac does.
        var seen = new HashSet<string>(comparer: StringComparer.Ordinal);
        while (parent is not null && seen.Add(item: parent.Id))
        {
            if (parent.Type == "Stage" && parent.Identifier != "__default" && parent.Name != "__default")
            {
                stage = parent.Name;
            }
            parent = parent.ParentId is { } next ? byId.GetValueOrDefault(key: next) : null;
        }
        var message = failed.Issues?.FirstOrDefault(predicate: issue => issue.Type == "error")?.Message is { } error ? Clean(message: error) : null;
        return new PipelineFailure(
            Stage: stage is null ? null : PlainText.SingleLine(text: stage),
            Step: PlainText.SingleLine(text: failed.Name ?? "A step"),
            Message: message is { Length: > 0 } ? message : null);
    }

    /// One line, without the log's `##[error]` prefix, at most 300 characters.
    internal static string Clean(string message)
    {
        const string Prefix = "##[error]";
        var text = PlainText.SingleLine(text: message);
        if (text.StartsWith(value: Prefix, comparisonType: StringComparison.Ordinal))
        {
            text = text[Prefix.Length..];
        }
        var info = new StringInfo(value: text);
        return info.LengthInTextElements > 300 ? info.SubstringByTextElements(startingTextElement: 0, lengthInTextElements: 299) + "…" : text;
    }

    static ADOTimelineRecord? Earliest(IReadOnlyList<ADOTimelineRecord> records, string type) => records
        .Where(predicate: record => record.Type == type && record.Result == "failed")
        .OrderBy(keySelector: record => record.FinishTime ?? DateTimeOffset.MaxValue)
        .ThenBy(keySelector: record => record.Order ?? int.MaxValue)
        .FirstOrDefault();
}
