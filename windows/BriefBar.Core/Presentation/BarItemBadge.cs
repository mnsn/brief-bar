namespace BriefBar.Core.Presentation;

/// What an item in the bar shows besides its counts, when its section doesn't show the whole story.
public enum BarItemBadge
{
    None,

    /// "…" after its name, while its first read runs.
    Starting,

    /// A warning, and a word or two such as "Sign in".
    Problem,

    /// Its counts, with a warning: they're from its last good refresh.
    Stale,

    /// A pause, and "Review".
    Paused,
}
