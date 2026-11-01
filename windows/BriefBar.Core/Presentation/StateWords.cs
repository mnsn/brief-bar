namespace BriefBar.Core.Presentation;

/// How states are said, the same for every source, in Windows' sentence case.
public static class StateWords
{
    /// A list's heading: "Needs you".
    public static string Title(ItemState state) => state switch
    {
        ItemState.NeedsYou => "Needs you",
        ItemState.Failing => "Something's wrong",
        ItemState.Running => "Running",
        ItemState.Done => "Done or ready",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(state), actualValue: state, message: "Not a state."),
    };

    /// After a count: "3 need you".
    public static string AfterCount(ItemState state) => state switch
    {
        ItemState.NeedsYou => "need you",
        ItemState.Failing => "went wrong",
        ItemState.Running => "running",
        ItemState.Done => "done or ready",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(state), actualValue: state, message: "Not a state."),
    };

    /// The icon a state shows next to its count. Copilot's stopped sessions show a warning, as on the Mac.
    public static IconKey Icon(ItemState state, SectionId section) => state switch
    {
        ItemState.NeedsYou => IconKey.HandRaise,
        ItemState.Failing => section == SectionId.CopilotSessions ? IconKey.Warning : IconKey.DismissCircle,
        ItemState.Running => IconKey.Flash,
        ItemState.Done => IconKey.CheckmarkCircle,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(state), actualValue: state, message: "Not a state."),
    };
}
