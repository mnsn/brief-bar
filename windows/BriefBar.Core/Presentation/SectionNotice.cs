namespace BriefBar.Core.Presentation;

/// What a section's panel says about what it shows, beside it, without its being a problem: GitHub's pull requests that
/// need single sign-on, or that there are more than it reads. `Command` is what its button does, if it has one, such as
/// "More on GitHub".
public sealed record SectionNotice(string Message)
{
    public PanelCommand? Command { get; init; }
}
