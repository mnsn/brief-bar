namespace BriefBar.Core.AzureDevOps;

/// Identifies a pull request: its number is unique within its organization, whose name Azure DevOps compares ignoring
/// case, as this does: `Contoso/7` is `contoso/7`. The Mac's `PRKey`, which says itself as `organization/number`, spelled
/// as it was given.
public readonly record struct PRKey(string Organization, int Number) : IComparable<PRKey>
{
    public static bool operator <(PRKey left, PRKey right) => left.CompareTo(other: right) < 0;

    public static bool operator >(PRKey left, PRKey right) => left.CompareTo(other: right) > 0;

    public static bool operator <=(PRKey left, PRKey right) => left.CompareTo(other: right) <= 0;

    public static bool operator >=(PRKey left, PRKey right) => left.CompareTo(other: right) >= 0;

    public bool Equals(PRKey other) =>
        Number == other.Number && string.Equals(a: Organization, b: other.Organization, comparisonType: StringComparison.OrdinalIgnoreCase);

    public override int GetHashCode() =>
        HashCode.Combine(value1: Organization is null ? 0 : StringComparer.OrdinalIgnoreCase.GetHashCode(obj: Organization), value2: Number);

    /// By organization, ignoring case, then number.
    public int CompareTo(PRKey other)
    {
        var organization = string.Compare(strA: Organization, strB: other.Organization, comparisonType: StringComparison.OrdinalIgnoreCase);
        return organization != 0 ? organization : Number.CompareTo(value: other.Number);
    }

    public override string ToString() => Organization + "/" + Number.ToString(provider: System.Globalization.CultureInfo.InvariantCulture);
}
