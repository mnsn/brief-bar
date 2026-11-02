namespace BriefBar.Core.Copilot;

/// What BriefBar knows of the GitHub Copilot desktop app, without asking Windows: the app's own link to a session, and
/// what's worth saying when its data can't be read. The app registers `ghapp:` links, on Windows as on the Mac. The
/// Mac's `CopilotApp`, whose Windows half is in the app (`CopilotAppShell`).
public static class CopilotApp
{
    /// What the section says when reading fails in a way BriefBar doesn't expect.
    public const string UnexpectedProblem = "BriefBar couldn't read your Copilot sessions.";

    /// `ghapp://sessions/<id>`, which opens a session or chat in the app.
    public static Uri SessionLink(string id)
    {
        ArgumentException.ThrowIfNullOrEmpty(argument: id);
        return new Uri(uriString: "ghapp://sessions/" + Uri.EscapeDataString(stringToEscape: id));
    }

    /// What to say couldn't be read: not the app's database on a PC without the app, as with only the Copilot CLI, which
    /// keeps none, so there's none to read. With the app, whatever the engine says.
    public static string? Problem(EngineSnapshot state, bool isInstalled)
    {
        ArgumentNullException.ThrowIfNull(argument: state);
        return state.DatabaseMissing && !isInstalled ? null : state.Problem;
    }
}
