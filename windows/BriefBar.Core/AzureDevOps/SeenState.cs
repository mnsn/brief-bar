using System.Text.Json.Nodes;
using BriefBar.Core.Settings;

namespace BriefBar.Core.AzureDevOps;

/// What you've seen, and what you've taken off Needs you, by one account. Azure DevOps has no read or unread state for pull
/// requests, so BriefBar keeps its own: activity up to `Baseline`, or up to when you last opened a pull request from
/// BriefBar or marked it seen, counts as seen. Comments you've seen still need you while they wait on you, until you take
/// the pull request off Needs you. Pull requests are named by `PRKey`'s `organization/number`, the organization in any
/// case, as Azure DevOps compares it. The Mac's `SeenState`.
public sealed record SeenState
{
    /// Names compared as Azure DevOps compares organizations: ignoring case.
    static readonly StringComparer names = StringComparer.OrdinalIgnoreCase;

    /// The first time, only the last few days count as new, so that years of old threads don't all need you.
    public static TimeSpan FirstRunLookback { get; } = TimeSpan.FromDays(value: 3);

    public SeenState(
        DateTimeOffset baseline,
        IReadOnlyDictionary<string, DateTimeOffset>? seenAt = null,
        IReadOnlyDictionary<string, DateTimeOffset>? dismissedAt = null,
        string? account = null)
    {
        Baseline = baseline;
        SeenAt = Merged(dates: seenAt);
        DismissedAt = Merged(dates: dismissedAt);
        Account = account;
    }

    /// Activity before this was there before BriefBar first ran.
    public DateTimeOffset Baseline { get; }

    /// When you last looked at each pull request.
    public IReadOnlyDictionary<string, DateTimeOffset> SeenAt { get; }

    /// When you last took each pull request off Needs you: comments up to then that still wait on you don't need you
    /// anymore. Never later than when you last looked at it.
    public IReadOnlyDictionary<string, DateTimeOffset> DismissedAt { get; }

    /// Whose this is (`AccessToken.Account`), once known: each account you sign in with has its own.
    public string? Account { get; init; }

    public static SeenState FirstRun(DateTimeOffset now, string? account = null) => new(baseline: now - FirstRunLookback, account: account);

    /// Activity up to this counts as seen.
    public DateTimeOffset Cutoff(PRKey key) => Later(first: Baseline, second: SeenAt.GetValueOrDefault(key: key.ToString(), defaultValue: DateTimeOffset.MinValue));

    /// Comments up to this that still wait on you don't need you anymore.
    public DateTimeOffset DismissedCutoff(PRKey key) => Later(first: Baseline, second: DismissedAt.GetValueOrDefault(key: key.ToString(), defaultValue: DateTimeOffset.MinValue));

    /// With `keys` seen at `date`, or later if you'd seen them since.
    public SeenState MarkingSeen(IEnumerable<PRKey> keys, DateTimeOffset date)
    {
        ArgumentNullException.ThrowIfNull(argument: keys);
        var seen = new Dictionary<string, DateTimeOffset>(collection: SeenAt, comparer: names);
        foreach (var key in keys)
        {
            var name = key.ToString();
            seen[name] = Later(first: date, second: seen.GetValueOrDefault(key: name, defaultValue: DateTimeOffset.MinValue));
        }
        return new SeenState(baseline: Baseline, seenAt: seen, dismissedAt: DismissedAt, account: Account);
    }

    /// With `keys` taken off Needs you up to `date`, which sees them too: what waited on you there doesn't anymore, and
    /// what comes after needs you again.
    public SeenState Dismissing(IEnumerable<PRKey> keys, DateTimeOffset date)
    {
        ArgumentNullException.ThrowIfNull(argument: keys);
        var all = keys.ToList();
        var dismissed = new Dictionary<string, DateTimeOffset>(collection: DismissedAt, comparer: names);
        foreach (var key in all)
        {
            var name = key.ToString();
            dismissed[name] = Later(first: date, second: dismissed.GetValueOrDefault(key: name, defaultValue: DateTimeOffset.MinValue));
        }
        return new SeenState(baseline: Baseline, seenAt: SeenAt, dismissedAt: dismissed, account: Account).MarkingSeen(keys: all, date: date);
    }

    /// Without the pull requests that aren't listed anymore and were last seen before `olderThan`.
    public SeenState Pruning(IReadOnlySet<PRKey> keeping, DateTimeOffset olderThan)
    {
        var (seen, dismissed) = Pruned(seenAt: SeenAt, dismissedAt: DismissedAt, keeping: keeping, olderThan: olderThan);
        return new SeenState(baseline: Baseline, seenAt: seen, dismissedAt: dismissed, account: Account);
    }

    /// What's left of when you last looked at pull requests and took them off Needs you, once those that aren't listed and
    /// were last seen before `olderThan` are forgotten. When you took one off goes with when you last looked at it, never
    /// before: you may have taken it off long ago and looked at it since, and forgetting only that would bring back what
    /// you took off, once it's listed again.
    public static (Dictionary<string, DateTimeOffset> SeenAt, Dictionary<string, DateTimeOffset> DismissedAt) Pruned(
        IReadOnlyDictionary<string, DateTimeOffset> seenAt, IReadOnlyDictionary<string, DateTimeOffset> dismissedAt, IReadOnlySet<PRKey> keeping, DateTimeOffset olderThan)
    {
        ArgumentNullException.ThrowIfNull(argument: seenAt);
        ArgumentNullException.ThrowIfNull(argument: dismissedAt);
        ArgumentNullException.ThrowIfNull(argument: keeping);
        var kept = keeping.Select(selector: key => key.ToString()).ToHashSet(comparer: names);
        var seen = Merged(dates: seenAt.Where(predicate: pair => kept.Contains(item: pair.Key) || pair.Value > olderThan));
        var dismissed = Merged(dates: dismissedAt.Where(predicate: pair => seen.ContainsKey(key: pair.Key) || kept.Contains(item: pair.Key) || pair.Value > olderThan));
        return (seen, dismissed);
    }

    public bool Equals(SeenState? other) =>
        other is not null && Baseline == other.Baseline && Account == other.Account
            && SameDates(first: SeenAt, second: other.SeenAt) && SameDates(first: DismissedAt, second: other.DismissedAt);

    public override int GetHashCode() => HashCode.Combine(value1: Baseline, value2: Account, value3: SeenAt.Count, value4: DismissedAt.Count);

    /// As it's saved: each time in seconds since 1970, as BriefBar saves times (`SettingsValues`).
    internal JsonObject ToJson()
    {
        var saved = new JsonObject
        {
            ["baseline"] = SettingsValues.DateNode(date: Baseline),
            ["seenAt"] = SettingsValues.DatesNode(dates: SeenAt),
            ["dismissedAt"] = SettingsValues.DatesNode(dates: DismissedAt),
        };
        if (Account is not null)
        {
            saved["account"] = Account;
        }
        return saved;
    }

    /// The state `node` saved, or null when it's missing or can't be read. One saved without `dismissedAt` took nothing
    /// off Needs you.
    internal static SeenState? FromJson(JsonNode? node)
    {
        if (node is not JsonObject saved || SettingsValues.DateFrom(node: saved["baseline"]) is not { } baseline || saved["seenAt"] is not JsonObject seen)
        {
            return null;
        }
        return new SeenState(
            baseline: baseline,
            seenAt: SettingsValues.DatesFrom(node: seen),
            dismissedAt: saved["dismissedAt"] is JsonObject dismissed ? SettingsValues.DatesFrom(node: dismissed) : null,
            account: saved["account"] is JsonValue account && account.TryGetValue(value: out string? name) ? name : null);
    }

    static bool SameDates(IReadOnlyDictionary<string, DateTimeOffset> first, IReadOnlyDictionary<string, DateTimeOffset> second) =>
        first.Count == second.Count
            && first.All(predicate: pair => second.TryGetValue(key: pair.Key, value: out var date) && date == pair.Value);

    /// `dates` by name, the organization in any case: of a name spelled two ways, the later time counts.
    static Dictionary<string, DateTimeOffset> Merged(IEnumerable<KeyValuePair<string, DateTimeOffset>>? dates)
    {
        var merged = new Dictionary<string, DateTimeOffset>(comparer: names);
        foreach (var (name, date) in dates ?? [])
        {
            merged[name] = Later(first: date, second: merged.GetValueOrDefault(key: name, defaultValue: DateTimeOffset.MinValue));
        }
        return merged;
    }

    static DateTimeOffset Later(DateTimeOffset first, DateTimeOffset second) => first > second ? first : second;
}
