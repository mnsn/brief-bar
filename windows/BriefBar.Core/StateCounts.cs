namespace BriefBar.Core;

/// How many things are in each state: a section's, or the sum of several sections'.
public readonly record struct StateCounts(int NeedsYou = 0, int Failing = 0, int Running = 0, int Done = 0)
{
    /// Every state, in the order lists show them: what needs you, what's wrong, what's running, what's done or ready.
    public static IReadOnlyList<ItemState> AllStates { get; } =
        [ItemState.NeedsYou, ItemState.Failing, ItemState.Running, ItemState.Done];

    public int this[ItemState state] => state switch
    {
        ItemState.NeedsYou => NeedsYou,
        ItemState.Failing => Failing,
        ItemState.Running => Running,
        ItemState.Done => Done,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(state), actualValue: state, message: "Not a state."),
    };

    /// Everything counted, in any state.
    public int Total => NeedsYou + Failing + Running + Done;

    /// A source's counts of its own groups, each added to the state it maps to. Groups with no state aren't counted.
    public static StateCounts FromGroups<TGroup>(IEnumerable<TGroup> groups, Func<TGroup, int> count, Func<TGroup, ItemState?> state)
    {
        ArgumentNullException.ThrowIfNull(argument: groups);
        ArgumentNullException.ThrowIfNull(argument: count);
        ArgumentNullException.ThrowIfNull(argument: state);
        var counts = new StateCounts();
        foreach (var group in groups)
        {
            if (state(arg: group) is { } itemState)
            {
                counts = counts.Adding(state: itemState, count: count(arg: group));
            }
        }
        return counts;
    }

    /// These counts with `count` more things in `state`.
    public StateCounts Adding(ItemState state, int count) => state switch
    {
        ItemState.NeedsYou => this with { NeedsYou = NeedsYou + count },
        ItemState.Failing => this with { Failing = Failing + count },
        ItemState.Running => this with { Running = Running + count },
        ItemState.Done => this with { Done = Done + count },
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(state), actualValue: state, message: "Not a state."),
    };

    public static StateCounts operator +(StateCounts left, StateCounts right) => Add(left: left, right: right);

    public static StateCounts Add(StateCounts left, StateCounts right) => new(
        NeedsYou: left.NeedsYou + right.NeedsYou,
        Failing: left.Failing + right.Failing,
        Running: left.Running + right.Running,
        Done: left.Done + right.Done);
}
