using System.Globalization;

namespace BriefBar.Core.Copilot;

/// The order a session list shows. The Mac's `SessionOrdering`.
public static class SessionOrdering
{
    static readonly Comparer<SessionSnapshot> order = Comparer<SessionSnapshot>.Create(comparison: Compare);

    /// By group; within Needs you, the longest-waiting first, otherwise the most recent first; then by name, as File
    /// Explorer sorts names, and by ID.
    public static List<SessionSnapshot> Sorted(IEnumerable<SessionSnapshot> snapshots) => [.. snapshots.Order(comparer: order)];

    static int Compare(SessionSnapshot? left, SessionSnapshot? right)
    {
        if (left is null || right is null)
        {
            return left is null ? (right is null ? 0 : -1) : 1;
        }
        if (left.Phase != right.Phase)
        {
            return ((int)left.Phase).CompareTo(value: (int)right.Phase);
        }
        var leftDate = left.Since ?? DateTimeOffset.MinValue;
        var rightDate = right.Since ?? DateTimeOffset.MinValue;
        if (leftDate != rightDate)
        {
            return left.Phase == DisplayPhase.NeedsYou ? leftDate.CompareTo(other: rightDate) : rightDate.CompareTo(other: leftDate);
        }
        var byName = CultureInfo.CurrentCulture.CompareInfo.Compare(
            string1: left.DisplayName, string2: right.DisplayName, options: CompareOptions.IgnoreCase | CompareOptions.NumericOrdering);
        return byName != 0 ? byName : string.CompareOrdinal(strA: left.Id, strB: right.Id);
    }
}
