using BriefBar.Core.Settings;

namespace BriefBar.Core.Copilot;

/// Copilot's settings, in BriefBar's, and the sessions you've cleared or viewed. Safe to use from any thread. The Mac's
/// `AppSettings`, in CopilotUI, with the same keys.
public sealed class CopilotSettings
{
    public const string KeepEndedMinutesKey = "copilot.keepEndedMinutes";
    public const string ShowContextUsageKey = "copilot.showContextUsage";
    public const string MoveViewedToIdleKey = "copilot.moveViewedToIdle";
    public const string ShowRelayedQuestionsOnceKey = "copilot.showRelayedQuestionsOnce";
    public const string NestSessionsKey = "copilot.nestSessions";
    public const string ClearedKey = "copilot.clearedSessions";
    public const string ViewedKey = "copilot.acknowledgedSessions";

    /// How long a dismissal is kept: a session that ended before that is idle anyway.
    static readonly TimeSpan dismissalsKept = TimeSpan.FromDays(value: 7);

    readonly Lock gate = new();
    readonly ISettingsStorage settings;
    int keepEndedMinutes;
    bool showContextUsage;
    bool moveViewedToIdle;
    bool showRelayedQuestionsOnce;
    bool nestSessions;
    Dictionary<string, DateTimeOffset> cleared;
    Dictionary<string, DateTimeOffset> viewed;

    public CopilotSettings(ISettingsStorage settings, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
        var minutes = settings.Number(key: KeepEndedMinutesKey);
        keepEndedMinutes = minutes > 0 ? minutes : 60;
        showContextUsage = settings.Bool(key: ShowContextUsageKey);
        moveViewedToIdle = settings.Bool(key: MoveViewedToIdleKey);
        showRelayedQuestionsOnce = settings.Bool(key: ShowRelayedQuestionsOnceKey);
        nestSessions = settings.Bool(key: NestSessionsKey);
        // Old acknowledgments include automatic dismissals just from viewing a session: they're kept only as viewed
        // markers, used while Move Viewed Sessions to Idle is on, never as explicit clears.
        var cutoff = now - dismissalsKept;
        cleared = Recent(dates: settings.Dates(key: ClearedKey), cutoff: cutoff);
        viewed = Recent(dates: settings.Dates(key: ViewedKey), cutoff: cutoff);
    }

    /// A setting, or the sessions cleared or viewed, changed. Raised on the thread that changed it.
    public event EventHandler? Changed;

    /// How long, in minutes, Keep Finished Sessions For offers to keep a finished or stopped session highlighted.
    public static IReadOnlyList<int> KeepEndedChoices { get; } = [15, 60, 240, 1_440];

    /// A choice of Keep finished sessions for, in words: "15 minutes", "1 hour", "4 hours", "1 day".
    public static string KeepEndedTitle(int minutes) => minutes switch
    {
        1_440 => "1 day",
        _ when minutes % 1_440 == 0 => (minutes / 1_440).ToString(provider: System.Globalization.CultureInfo.InvariantCulture) + " days",
        60 => "1 hour",
        _ when minutes % 60 == 0 => (minutes / 60).ToString(provider: System.Globalization.CultureInfo.InvariantCulture) + " hours",
        1 => "1 minute",
        _ => minutes.ToString(provider: System.Globalization.CultureInfo.InvariantCulture) + " minutes",
    };

    /// How long finished and stopped sessions stay highlighted unless you clear them, in minutes.
    public int KeepEndedMinutes
    {
        get => Read(value: () => keepEndedMinutes);
        set
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(value: value);
            Write(change: () => Swap(field: ref keepEndedMinutes, value: value), save: () => settings.SetNumber(key: KeepEndedMinutesKey, value: value));
        }
    }

    /// Shows how full each session's context window is.
    public bool ShowContextUsage
    {
        get => Read(value: () => showContextUsage);
        set => Write(change: () => Swap(field: ref showContextUsage, value: value), save: () => settings.SetBool(key: ShowContextUsageKey, value: value));
    }

    /// Opt-in: viewing an ended session dismisses it before Keep Finished Sessions For passes.
    public bool MoveViewedToIdle
    {
        get => Read(value: () => moveViewedToIdle);
        set => Write(change: () => Swap(field: ref moveViewedToIdle, value: value), save: () => settings.SetBool(key: MoveViewedToIdleKey, value: value));
    }

    /// Opt-in: a question or plan that a coordinating session asks you for another shows once, where you answer it
    /// (`RelayedQuestions`).
    public bool ShowRelayedQuestionsOnce
    {
        get => Read(value: () => showRelayedQuestionsOnce);
        set => Write(change: () => Swap(field: ref showRelayedQuestionsOnce, value: value), save: () => settings.SetBool(key: ShowRelayedQuestionsOnceKey, value: value));
    }

    /// Opt-in: a session that another one started shows under it, as the Copilot app's sidebar nests it, when both are in
    /// the same group (`SessionNesting`).
    public bool NestSessions
    {
        get => Read(value: () => nestSessions);
        set => Write(change: () => Swap(field: ref nestSessions, value: value), save: () => settings.SetBool(key: NestSessionsKey, value: value));
    }

    /// Session ID → when you last cleared its finished or stopped run.
    public IReadOnlyDictionary<string, DateTimeOffset> Cleared => Read(value: () => new Dictionary<string, DateTimeOffset>(dictionary: cleared));

    /// Session ID → when you last viewed it, which only Move Viewed Sessions to Idle uses.
    public IReadOnlyDictionary<string, DateTimeOffset> Viewed => Read(value: () => new Dictionary<string, DateTimeOffset>(dictionary: viewed));

    /// How sessions are resolved, as these settings say.
    public ResolverOptions Options => Read(value: () => new ResolverOptions
    {
        RecentWindow = TimeSpan.FromMinutes(value: keepEndedMinutes),
        MoveViewedToIdle = moveViewedToIdle,
        ShowRelayedQuestionsOnce = showRelayedQuestionsOnce,
    });

    public DateTimeOffset? ClearedAt(string id) => Read(value: () => cleared.TryGetValue(key: id, value: out var date) ? date : (DateTimeOffset?)null);

    public DateTimeOffset? ViewedAt(string id) => Read(value: () => viewed.TryGetValue(key: id, value: out var date) ? date : (DateTimeOffset?)null);

    /// Dismisses the sessions' runs that ended by `date`: Clear.
    public void Clear(IEnumerable<string> ids, DateTimeOffset date) =>
        Mark(ids: ids, date: date, dates: () => cleared, key: ClearedKey);

    public void MarkViewed(IEnumerable<string> ids, DateTimeOffset date) =>
        Mark(ids: ids, date: date, dates: () => viewed, key: ViewedKey);

    /// Forgets the sessions you cleared or viewed, as turning Copilot off does: both saved lists go, with any dismissal
    /// older than a week, which isn't in memory. Its settings stay.
    public void ForgetDismissed()
    {
        bool had;
        lock (gate)
        {
            had = cleared.Count > 0 || viewed.Count > 0;
            cleared = new Dictionary<string, DateTimeOffset>(comparer: StringComparer.Ordinal);
            viewed = new Dictionary<string, DateTimeOffset>(comparer: StringComparer.Ordinal);
            settings.Write(key: ClearedKey, value: null);
            settings.Write(key: ViewedKey, value: null);
        }
        if (had)
        {
            Changed?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    static Dictionary<string, DateTimeOffset> Recent(Dictionary<string, DateTimeOffset> dates, DateTimeOffset cutoff) =>
        dates.Where(predicate: pair => pair.Value > cutoff).ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value, comparer: StringComparer.Ordinal);

    static bool Swap<T>(ref T field, T value)
    {
        if (EqualityComparer<T>.Default.Equals(x: field, y: value))
        {
            return false;
        }
        field = value;
        return true;
    }

    void Mark(IEnumerable<string> ids, DateTimeOffset date, Func<Dictionary<string, DateTimeOffset>> dates, string key)
    {
        ArgumentNullException.ThrowIfNull(argument: ids);
        Dictionary<string, DateTimeOffset>? changed = null;
        Write(
            change: () =>
            {
                var current = dates();
                foreach (var id in ids)
                {
                    if (!current.TryGetValue(key: id, value: out var existing) || existing != date)
                    {
                        current[id] = date;
                        changed = current;
                    }
                }
                return changed is not null;
            },
            save: () => settings.SetDates(key: key, dates: changed!));
    }

    T Read<T>(Func<T> value)
    {
        lock (gate)
        {
            return value();
        }
    }

    /// Changes a setting under the lock, saves it if it changed, and says so, outside the lock.
    void Write(Func<bool> change, Action save)
    {
        lock (gate)
        {
            if (!change())
            {
                return;
            }
            save();
        }
        Changed?.Invoke(sender: this, e: EventArgs.Empty);
    }
}
