namespace BriefBar.Core.Copilot;

/// How sessions are resolved, from Copilot's settings.
public sealed record ResolverOptions
{
    /// How long finished and stopped sessions stay highlighted before turning idle.
    public TimeSpan RecentWindow { get; init; } = TimeSpan.FromHours(value: 1);

    /// Silence after which a running log that the app no longer marks as running is considered dead.
    public TimeSpan StaleAfter { get; init; } = TimeSpan.FromSeconds(value: 90);

    /// How long to trust the app's running flag before the CLI has written anything.
    public TimeSpan StartingGrace { get; init; } = TimeSpan.FromSeconds(value: 120);

    /// Whether a session viewed since it ended moves to idle before the recent window expires.
    public bool MoveViewedToIdle { get; init; }

    /// Whether a session relaying another's question waits for your answer (`RelayedQuestions`). Off, it's working, and
    /// the session it relays for needs you on its own.
    public bool ShowRelayedQuestionsOnce { get; init; }
}
