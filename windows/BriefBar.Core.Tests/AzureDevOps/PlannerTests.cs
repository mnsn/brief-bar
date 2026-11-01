using BriefBar.Core.AzureDevOps;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Which pull requests' details a refresh reads.
public sealed class PlannerTests
{
    static readonly RefreshPlannerOptions options = new()
    {
        BusyInterval = TimeSpan.FromSeconds(value: 60),
        ActiveInterval = TimeSpan.FromSeconds(value: 180),
        QuietInterval = TimeSpan.FromSeconds(value: 900),
        Budget = 3,
    };

    [Fact]
    public void NewAndChangedFirstThenTheOldestDue()
    {
        var cache = new Dictionary<PRKey, RefreshPlannerEntry>
        {
            [Key(number: 2)] = new(FetchedAt: T(seconds: -10), Fingerprint: "old"),
            [Key(number: 3)] = new(FetchedAt: T(seconds: -61), Fingerprint: "f", IsBusy: true),
            [Key(number: 4)] = new(FetchedAt: T(seconds: -500), Fingerprint: "f"),
            [Key(number: 5)] = new(FetchedAt: T(seconds: -200), Fingerprint: "f"),
            [Key(number: 6)] = new(FetchedAt: T(seconds: -100), Fingerprint: "f"),
            [Key(number: 7)] = new(FetchedAt: T(seconds: -800), Fingerprint: "f", IsQuiet: true),
            [Key(number: 8)] = new(FetchedAt: T(seconds: -901), Fingerprint: "f", IsQuiet: true),
        };
        var candidates = Enumerable.Range(start: 1, count: 8).Select(selector: number => Candidate(number: number)).ToList();
        var all = RefreshPlanner.Plan(candidates: candidates, cache: cache, now: T(seconds: 0), options: options, limit: null);
        Assert.Equal(expected: [1, 2, 3, 8, 4, 5], actual: Numbers(keys: all));
        // The budget is for refreshing known pull requests: new ones are always fetched.
        var budgeted = RefreshPlanner.Plan(candidates: candidates, cache: cache, now: T(seconds: 0), options: options, limit: 2);
        Assert.Equal(expected: [1, 2, 3], actual: Numbers(keys: budgeted));
        var more = Enumerable.Range(start: 9, count: 4).Select(selector: number => Candidate(number: number));
        var withNew = RefreshPlanner.Plan(candidates: candidates.Concat(second: more), cache: cache, now: T(seconds: 0), options: options, limit: 1);
        Assert.Equal(expected: [1, 9, 10, 11, 12, 2], actual: Numbers(keys: withNew));
    }

    [Fact]
    public void NothingIsDueRightAfterAFetch()
    {
        var cache = new Dictionary<PRKey, RefreshPlannerEntry> { [Key(number: 1)] = new(FetchedAt: T(seconds: 0), Fingerprint: "f", IsBusy: true) };
        Assert.Empty(collection: RefreshPlanner.Plan(candidates: [Candidate(number: 1)], cache: cache, now: T(seconds: 30), options: options, limit: null));
    }

    static PRKey Key(int number) => new(Organization: "contoso", Number: number);

    static RefreshPlannerCandidate Candidate(int number, string fingerprint = "f") => new(Key: Key(number: number), Fingerprint: fingerprint);

    static IEnumerable<int> Numbers(IEnumerable<PRKey> keys) => keys.Select(selector: key => key.Number);
}
