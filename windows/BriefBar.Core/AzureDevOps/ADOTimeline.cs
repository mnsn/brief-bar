using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A run's stages, jobs and tasks, from `{project}/_apis/build/builds/{id}/timeline`, without the records that can't be
/// read; none when it has no `records`.
public sealed record ADOTimeline(IReadOnlyList<ADOTimelineRecord> Records)
{
    internal static ADOTimeline Read(JsonElement element) =>
        new(Records: LenientJson.Items(element: element, name: "records", read: ADOTimelineRecord.Read) ?? []);
}
