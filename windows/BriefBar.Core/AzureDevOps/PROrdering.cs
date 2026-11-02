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

    /// In the order you chose: by status, as `Sorted`; or by when each was created, whatever its group. One made up without
    /// the date it was created comes last, either way; those created at the same time, by organization and number, the
    /// same way round as their dates.
    public static IReadOnlyList<PRSnapshot> Sorted(IEnumerable<PRSnapshot> snapshots, PROrder order)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        if (!order.IsByDate())
        {
            return Sorted(snapshots: snapshots);
        }
        var undated = snapshots.OrderBy(keySelector: snapshot => snapshot.CreatedAt is null ? 1 : 0);
        return (order == PROrder.NewestFirst
                ? undated.ThenByDescending(keySelector: snapshot => snapshot.CreatedAt).ThenByDescending(keySelector: snapshot => snapshot.Key)
                : undated.ThenBy(keySelector: snapshot => snapshot.CreatedAt).ThenBy(keySelector: snapshot => snapshot.Key))
            .ToList();
    }
}
