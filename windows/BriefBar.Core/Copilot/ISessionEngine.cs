namespace BriefBar.Core.Copilot;

/// What reads the Copilot app's sessions for `CopilotSource`: `SessionEngine`, or made-up sessions for the demo. It hands
/// each new `EngineSnapshot` to the handler it was made with.
public interface ISessionEngine
{
    /// Starts reading, and hands over what it read first, once it's read it.
    void Start();

    /// Stops reading, and gives back whatever it holds open.
    [System.Diagnostics.CodeAnalysis.SuppressMessage(
        category: "Naming", checkId: "CA1716", Justification = "The Mac's SessionEngine names it so; no other language implements it.")]
    void Stop();

    /// Reads everything again, and hands it over if it changed.
    void Refresh();
}
