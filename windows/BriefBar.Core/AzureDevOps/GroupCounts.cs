namespace BriefBar.Core.AzureDevOps;

/// How many pull requests are in each group. The Mac's `GroupCounts`.
public sealed record GroupCounts
{
    readonly int[] counts = new int[PRGroups.All.Count];

    public GroupCounts()
    {
    }

    public GroupCounts(IEnumerable<PRSnapshot> snapshots)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        foreach (var snapshot in snapshots)
        {
            counts[(int)snapshot.Group]++;
        }
    }

    public int this[PRGroup group] => counts[(int)group];

    /// Pull requests worth showing: everything but idle.
    public int Active => PRGroups.All.Where(predicate: group => group != PRGroup.Idle).Sum(selector: group => this[group]);

    /// The pull requests the bar counts, by state.
    public StateCounts States(bool showToReview) =>
        StateCounts.FromGroups(groups: PRGroups.All, count: group => this[group], state: group => group.State(showToReview: showToReview));

    public bool Equals(GroupCounts? other) => other is not null && counts.AsSpan().SequenceEqual(other: other.counts);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var count in counts)
        {
            hash.Add(value: count);
        }
        return hash.ToHashCode();
    }
}
