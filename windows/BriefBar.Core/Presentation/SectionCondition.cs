namespace BriefBar.Core.Presentation;

/// Whether a section shows the whole story.
public enum SectionCondition
{
    /// Its first read is still running.
    Starting,

    /// It shows what's there: as it changes, or as of its last refresh.
    Ready,

    /// A refresh failed: it shows what was there at its last good one.
    Stale,

    /// It can't read, such as without a sign-in: it says why, and how to fix it.
    Problem,

    /// It reads more now than when you turned it on, so it waits until you've seen what.
    Paused,
}
