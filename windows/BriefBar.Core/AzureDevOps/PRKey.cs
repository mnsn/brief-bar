namespace BriefBar.Core.AzureDevOps;

/// Identifies a pull request: its number is unique within its organization. The Mac's `PRKey`, which says itself as
/// `organization/number`.
public readonly record struct PRKey(string Organization, int Number) : IComparable<PRKey>
{
    public static bool operator <(PRKey left, PRKey right) => left.CompareTo(other: right) < 0;

    public static bool operator >(PRKey left, PRKey right) => left.CompareTo(other: right) > 0;

    public static bool operator <=(PRKey left, PRKey right) => left.CompareTo(other: right) <= 0;

    public static bool operator >=(PRKey left, PRKey right) => left.CompareTo(other: right) >= 0;

    /// By organization, then number.
    public int CompareTo(PRKey other)
    {
        var organization = string.CompareOrdinal(strA: Organization, strB: other.Organization);
        return organization != 0 ? organization : Number.CompareTo(value: other.Number);
    }

    public override string ToString() => Organization + "/" + Number.ToString(provider: System.Globalization.CultureInfo.InvariantCulture);
}
