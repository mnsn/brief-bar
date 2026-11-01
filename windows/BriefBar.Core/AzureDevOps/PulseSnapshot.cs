namespace BriefBar.Core.AzureDevOps;

/// Everything the engine knows at one moment: the pull requests (`Records`), the organizations watched, whose sign-in it
/// is (`Account`) and your name, when each organization's lists were first read (what happened there before is in the
/// panel, not news), why the list may be out of date, when it was refreshed, and the pull requests asked for by their
/// links that turned out to be closed, gone, or not yours to read. The Mac's `PulseSnapshot`.
public sealed record PulseSnapshot
{
    public ValueList<PRRecord> Records { get; init; } = [];

    public ValueList<string> Organizations { get; init; } = [];

    public string? Account { get; init; }

    public string? UserName { get; init; }

    public IReadOnlyDictionary<string, DateTimeOffset> FirstLoaded { get; init; } = new Dictionary<string, DateTimeOffset>();

    public PulseProblem? Problem { get; init; }

    public DateTimeOffset? RefreshedAt { get; init; }

    public bool IsRefreshing { get; init; }

    public bool HasLoaded { get; init; }

    public IReadOnlySet<PRKey> ClosedLinks { get; init; } = new HashSet<PRKey>();

    /// When `organization`'s lists were first read, however its name is spelled: a pull request read under another
    /// spelling, as before finding your organizations again spelled it as Azure DevOps does, is of the same organization.
    public DateTimeOffset? FirstRead(string organization)
    {
        if (FirstLoaded.TryGetValue(key: organization, value: out var date))
        {
            return date;
        }
        foreach (var (name, first) in FirstLoaded)
        {
            if (string.Equals(a: name, b: organization, comparisonType: StringComparison.OrdinalIgnoreCase))
            {
                return first;
            }
        }
        return null;
    }

    public bool Equals(PulseSnapshot? other) =>
        other is not null
            && Records.Equals(other: other.Records)
            && Organizations.Equals(other: other.Organizations)
            && Account == other.Account
            && UserName == other.UserName
            && FirstLoaded.Count == other.FirstLoaded.Count
            && FirstLoaded.All(predicate: pair => other.FirstLoaded.TryGetValue(key: pair.Key, value: out var date) && date == pair.Value)
            && Equals(objA: Problem, objB: other.Problem)
            && RefreshedAt == other.RefreshedAt
            && IsRefreshing == other.IsRefreshing
            && HasLoaded == other.HasLoaded
            && ClosedLinks.SetEquals(other: other.ClosedLinks);

    public override int GetHashCode() => HashCode.Combine(value1: Records, value2: Account, value3: Problem, value4: RefreshedAt, value5: IsRefreshing, value6: HasLoaded);
}
