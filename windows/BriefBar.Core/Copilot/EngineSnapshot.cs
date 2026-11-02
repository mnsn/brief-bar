namespace BriefBar.Core.Copilot;

/// Everything the engine knows at one point in time. The Mac's `EngineSnapshot`.
public sealed record EngineSnapshot
{
    public ValueList<SessionRecord> Records { get; init; } = ValueList<SessionRecord>.Empty;

    public AppViewState View { get; init; } = new();

    /// Set when the Copilot data couldn't be read, to show in place of an empty list.
    public string? Problem { get; init; }

    /// The sessions are the ones the app's database lists, rather than every recent session folder, which is all there is
    /// to go on while the database has never been readable (`SessionStateScanner`).
    public bool ListedByApp { get; init; } = true;

    /// There's a Copilot folder, but nothing at all where the app's database goes, as on a PC with only the Copilot CLI,
    /// which keeps none; not a database that's there but can't be reached. Looked at on every read that fails.
    public bool DatabaseMissing { get; init; }
}
