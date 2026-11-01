namespace BriefBar.Core.Presentation;

/// How a section stands: its condition; when it last read what it shows, or that it follows changes as they happen
/// (`IsLive`); and, for a problem or a stale read, what's wrong in a sentence that names the source (`Problem`) and in a
/// word or two for the bar (`ShortProblem`, such as "Sign in").
public sealed record SectionStatus(
    SectionCondition Condition,
    DateTimeOffset? UpdatedAt = null,
    bool IsLive = false,
    string? Problem = null,
    string? ShortProblem = null)
{
    public static SectionStatus Starting { get; } = new(Condition: SectionCondition.Starting);

    /// Follows changes as they happen, as Copilot and Teams do.
    public static SectionStatus Live { get; } = new(Condition: SectionCondition.Ready, IsLive: true);

    /// Shows what was there at `time`, as Azure DevOps and GitHub do between refreshes.
    public static SectionStatus Updated(DateTimeOffset time) => new(Condition: SectionCondition.Ready, UpdatedAt: time);
}
