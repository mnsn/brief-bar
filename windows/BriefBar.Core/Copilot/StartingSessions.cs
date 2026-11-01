namespace BriefBar.Core.Copilot;

/// The sessions being opened in a terminal, since when. A new terminal window takes a moment to start the Copilot CLI,
/// which holds the session only once it starts: a second click meanwhile would start a second CLI on it, and fork its
/// history. So for a while, opening it again opens nothing more. Opening stops for good with `StopAll`, once what's going
/// on (`RunUnlessStopped`) is done. Safe to use from any thread. The Mac's `CLISession.Starting`.
public sealed class StartingSessions
{
    readonly Lock gate = new();

    /// Held while a session goes on opening, and to stop: taken before `gate`, never while holding it.
    readonly Lock opening = new();
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

    /// Runs `open`, which goes on opening a session that began in `round`, unless opening has stopped since: false then,
    /// and it doesn't run. `StopAll` waits for one that's running, so none runs once it has returned; so `open` mustn't
    /// wait for whatever stops opening.
    public bool RunUnlessStopped(int round, Action open)
    {
        ArgumentNullException.ThrowIfNull(argument: open);
        lock (opening)
        {
            if (Round != round)
            {
                return false;
            }
            open();
            return true;
        }
    }

    /// Stops opening every session, as when Copilot is turned off, once a session that's going on opening is done: none
    /// goes on from then.
    public void StopAll()
    {
        lock (opening)
        {
            lock (gate)
            {
                since.Clear();
                round++;
            }
        }
    }
}
