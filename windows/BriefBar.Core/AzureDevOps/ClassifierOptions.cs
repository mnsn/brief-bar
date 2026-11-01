namespace BriefBar.Core.AzureDevOps;

/// How long things stay where they are: pull requests without activity for `InactiveAfter` are idle, or never with
/// null; completed and abandoned ones stay in Done for `KeepDoneFor`; one someone sent you needs you for
/// `KeepChatLinksFor` unless you act on it sooner; and what you answered stays in Answered for `KeepAnsweredFor` if you
/// don't open the panel. The Mac's `ClassifierOptions`.
public sealed record ClassifierOptions
{
    public TimeSpan? InactiveAfter { get; init; } = TimeSpan.FromDays(value: 14);

    public TimeSpan KeepDoneFor { get; init; } = TimeSpan.FromDays(value: 1);

    public TimeSpan KeepChatLinksFor { get; init; } = TimeSpan.FromDays(value: 7);

    public TimeSpan KeepAnsweredFor { get; init; } = TimeSpan.FromDays(value: 1);
}
