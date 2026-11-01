namespace BriefBar.Core.AzureDevOps;

/// The order pull requests are listed in. The Mac's `PROrdering`.
public static class PROrdering
{
    /// By group; within a group, the most recent first, then by organization and number.
    public static IReadOnlyList<PRSnapshot> Sorted(IEnumerable<PRSnapshot> snapshots)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        return snapshots
            .OrderBy(keySelector: snapshot => snapshot.Group)
            .ThenByDescending(keySelector: snapshot => snapshot.Since ?? DateTimeOffset.MinValue)
            .ThenBy(keySelector: snapshot => snapshot.Key)
            .ToList();
    }
}
