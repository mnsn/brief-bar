namespace BriefBar.Core.Copilot;

/// What a session's group means for every source, and what the list calls it.
public static class DisplayPhases
{
    public static IReadOnlyList<DisplayPhase> All { get; } = Enum.GetValues<DisplayPhase>();

    /// The state it counts in, the same for every source: a session that stopped (interrupted, failed or stopped
    /// responding) is something wrong. Idle sessions aren't counted.
    public static ItemState? State(this DisplayPhase phase) => phase switch
    {
        DisplayPhase.NeedsYou => ItemState.NeedsYou,
        DisplayPhase.Running => ItemState.Running,
        DisplayPhase.Done => ItemState.Done,
        DisplayPhase.Stopped => ItemState.Failing,
        DisplayPhase.Idle => null,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(phase), actualValue: phase, message: "Not a phase."),
    };

    /// Its group's title, as the user guide names it: "Needs you".
    public static string Title(this DisplayPhase phase) => phase switch
    {
        DisplayPhase.NeedsYou => "Needs you",
        DisplayPhase.Running => "Running",
        DisplayPhase.Done => "Done",
        DisplayPhase.Stopped => "Stopped",
        DisplayPhase.Idle => "Idle",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(phase), actualValue: phase, message: "Not a phase."),
    };
}
