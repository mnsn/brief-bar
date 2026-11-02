namespace BriefBar.Core.Copilot;

/// Where a session opens: in the GitHub Copilot app; on a PC without the app, in a terminal with the Copilot CLI
/// (`CLISession`); or nowhere.
public enum SessionOpening
{
    Nowhere,
    App,
    Terminal,
}
