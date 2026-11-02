namespace BriefBar.Core.GitHub;

/// How many pull requests are in each group. The Mac's `GitHubGroupCounts`.
public sealed record GitHubGroupCounts
{
    readonly int[] counts = new int[GitHubPRGroups.All.Count];

    public GitHubGroupCounts()
    {
    }

    public GitHubGroupCounts(IEnumerable<GitHubPRSnapshot> snapshots)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        foreach (var snapshot in snapshots)
        {
            counts[(int)snapshot.Group]++;
        }
    }

    public int this[GitHubPRGroup group] => counts[(int)group];

    public int Total => counts.Sum();

    /// The pull requests that need you: to review, or with changes requested.
    public int NeedsYou => States.NeedsYou;

    /// The pull requests the bar counts, by state, for an item that adds them up across sources.
    public StateCounts States => StateCounts.FromGroups(groups: GitHubPRGroups.All, count: group => this[group], state: group => group.State());

    public bool Equals(GitHubGroupCounts? other) => other is not null && counts.AsSpan().SequenceEqual(other: other.counts);

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
