namespace BriefBar.Core.Copilot;

/// The sessions being opened in a terminal, since when. A new terminal window takes a moment to start the Copilot CLI,
/// which holds the session only once it starts: a second click meanwhile would start a second CLI on it, and fork its
/// history. So for a while, opening it again opens nothing more. Safe to use from any thread. The Mac's
/// `CLISession.Starting`.
public sealed class StartingSessions
{
    readonly Lock gate = new();
    readonly Dictionary<string, DateTimeOffset> since = new(comparer: StringComparer.Ordinal);
    int round;

    /// Long enough for a terminal to start the CLI.
    public static TimeSpan Window { get; } = TimeSpan.FromSeconds(value: 30);

    /// How many times opening stopped (`StopAll`): a session that began opening before then opens nothing.
    public int Round
    {
        get
        {
            lock (gate)
            {
                return round;
            }
        }
    }

    /// Starts opening session `id` at `now`, unless it's being opened already: false then.
    public bool Begin(string id, DateTimeOffset now)
    {
        lock (gate)
        {
            if (since.TryGetValue(key: id, value: out var started) && now - started < Window)
            {
                return false;
            }
            since[id] = now;
            return true;
        }
    }

    /// It's open, or couldn't be opened: the next click opens it again.
    public void End(string id)
    {
        lock (gate)
        {
            since.Remove(key: id);
        }
    }

    /// Stops opening every session, as when Copilot is turned off.
    public void StopAll()
    {
        lock (gate)
        {
            since.Clear();
            round++;
        }
    }
}
