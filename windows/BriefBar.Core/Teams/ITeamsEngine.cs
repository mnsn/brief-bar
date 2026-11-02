namespace BriefBar.Core.Teams;

/// What reads Teams' data for `TeamsSource`: `TeamsEngine`, or made-up chats for the demo. It hands each new
/// `TeamsSnapshot` to the handler it was made with.
public interface ITeamsEngine
{
    /// Starts reading, and hands over what it read first, once it's read it.
    void Start();

    /// Stops reading, and gives back whatever it holds open.
    [System.Diagnostics.CodeAnalysis.SuppressMessage(
        category: "Naming", checkId: "CA1716", Justification = "The Mac's engines name it so; no other language implements it.")]
    void Stop();

    /// Reads what changed, and hands it over if anything did.
    void Refresh();
}
