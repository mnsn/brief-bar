namespace BriefBar.Core.Tests;

/// Ported from Tests/BriefBarCoreTests/ItemStateTests.swift.
public sealed class ItemStateTests
{
    /// A source's own groups, as they'd map onto the shared states.
    enum Group
    {
        Asks,
        Waits,
        Broke,
        Works,
        Finished,
        Hidden,
    }

    static ItemState? StateOf(Group group) => group switch
    {
        Group.Asks or Group.Waits => ItemState.NeedsYou,
        Group.Broke => ItemState.Failing,
        Group.Works => ItemState.Running,
        Group.Finished => ItemState.Done,
        _ => null,
    };

    [Fact]
    public void AddsEachGroupToItsStateAndLeavesOutGroupsWithNone()
    {
        var counts = new Dictionary<Group, int>
        {
            [Group.Asks] = 2,
            [Group.Waits] = 1,
            [Group.Broke] = 3,
            [Group.Works] = 4,
            [Group.Finished] = 5,
            [Group.Hidden] = 100,
        };
        var states = StateCounts.FromGroups(groups: Enum.GetValues<Group>(), count: group => counts[group], state: StateOf);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 3, Running: 4, Done: 5), actual: states);
        Assert.Equal(expected: [3, 3, 4, 5], actual: StateCounts.AllStates.Select(selector: state => states[state]));
        Assert.Equal(expected: 15, actual: states.Total);
        Assert.Equal(expected: 0, actual: new StateCounts().Total);
    }

    [Fact]
    public void AddsUpSections()
    {
        var chats = new StateCounts(NeedsYou: 2);
        var pullRequests = new StateCounts(NeedsYou: 3, Failing: 2, Done: 2);
        var sessions = new StateCounts(NeedsYou: 3, Failing: 1, Running: 2, Done: 1);
        Assert.Equal(expected: new StateCounts(NeedsYou: 8, Failing: 3, Running: 2, Done: 3), actual: chats + pullRequests + sessions);

        var sum = new StateCounts() + sessions;
        sum = sum.Adding(state: ItemState.Running, count: 1);
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 1, Running: 3, Done: 1), actual: sum);
    }

    [Fact]
    public void ListsTheStatesInTheOrderListsShowThem()
    {
        Assert.Equal(
            expected: [ItemState.NeedsYou, ItemState.Failing, ItemState.Running, ItemState.Done],
            actual: StateCounts.AllStates);
        Assert.Equal(expected: Enum.GetValues<ItemState>(), actual: StateCounts.AllStates);
    }

    [Fact]
    public void RefusesSomethingThatIsntAState()
    {
        Assert.Throws<ArgumentOutOfRangeException>(testCode: () => new StateCounts()[(ItemState)42]);
        Assert.Throws<ArgumentOutOfRangeException>(testCode: () => new StateCounts().Adding(state: (ItemState)42, count: 1));
    }
}
