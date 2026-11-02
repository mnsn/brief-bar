using System.Text.Json;
using System.Text.Json.Nodes;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Teams;

/// Teams' settings, in BriefBar's, with the Mac's keys: whether rows show the messages' text, and how long a message stays
/// unread. Safe to use from any thread. The Mac's `AppSettings`, in TeamsUI, without the two that are how Windows reads
/// Teams (Mark Chats Read When You Read Them in Teams, and Mark All Read When Teams' Badge Clears) and without summaries,
/// which come later.
public sealed class TeamsSettings
{
    public const string ShowPreviewsKey = "teams.showMessagePreviews";
    public const string KeepUnreadKey = "teams.keepUnread";

    readonly Lock gate = new();
    readonly ISettingsStorage settings;
    bool showMessagePreviews;
    KeepUnread keepUnread;

    public TeamsSettings(ISettingsStorage settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
        // On unless you turned it off, as on the Mac.
        showMessagePreviews = settings.Read(key: ShowPreviewsKey) is not JsonValue saved || saved.GetValueKind() != JsonValueKind.False;
        keepUnread = settings.Read(key: KeepUnreadKey) is JsonValue value && value.TryGetValue(value: out string? raw) && Parse(rawValue: raw) is { } choice
            ? choice
            : KeepUnread.OneDay;
    }

    /// A setting changed. Raised on the thread that changed it.
    public event EventHandler? Changed;

    public static IReadOnlyList<KeepUnread> KeepUnreadChoices { get; } = [KeepUnread.FourHours, KeepUnread.OneDay, KeepUnread.ThreeDays, KeepUnread.UntilRead];

    /// Shows each chat's newest message under it, and what it says in the brief. Off, a row says how many messages are
    /// unread instead.
    public bool ShowMessagePreviews
    {
        get
        {
            lock (gate)
            {
                return showMessagePreviews;
            }
        }
        set
        {
            lock (gate)
            {
                if (showMessagePreviews == value)
                {
                    return;
                }
                showMessagePreviews = value;
                settings.SetBool(key: ShowPreviewsKey, value: value);
            }
            Changed?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    /// How long a message stays unread when BriefBar doesn't see it read.
    public KeepUnread KeepUnread
    {
        get
        {
            lock (gate)
            {
                return keepUnread;
            }
        }
        set
        {
            lock (gate)
            {
                if (keepUnread == value || !KeepUnreadChoices.Contains(value: value))
                {
                    return;
                }
                keepUnread = value;
                settings.Write(key: KeepUnreadKey, value: JsonValue.Create(value: RawValue(choice: value)));
            }
            Changed?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    /// Keep Unread For's choice as a time, or null for Until I Read It.
    public TimeSpan? KeepUnreadFor => Interval(choice: KeepUnread);

    /// "4 hours", "1 day", "3 days", "Until I read it".
    public static string KeepUnreadTitle(KeepUnread choice) => choice switch
    {
        KeepUnread.FourHours => "4 hours",
        KeepUnread.OneDay => "1 day",
        KeepUnread.ThreeDays => "3 days",
        _ => "Until I read it",
    };

    public static TimeSpan? Interval(KeepUnread choice) => choice switch
    {
        KeepUnread.FourHours => TimeSpan.FromHours(value: 4),
        KeepUnread.OneDay => TimeSpan.FromDays(value: 1),
        KeepUnread.ThreeDays => TimeSpan.FromDays(value: 3),
        _ => null,
    };

    /// The name it's saved under, as the Mac's raw values.
    public static string RawValue(KeepUnread choice) => choice switch
    {
        KeepUnread.FourHours => "fourHours",
        KeepUnread.OneDay => "oneDay",
        KeepUnread.ThreeDays => "threeDays",
        _ => "untilRead",
    };

    static KeepUnread? Parse(string? rawValue) =>
        KeepUnreadChoices.Cast<KeepUnread?>().FirstOrDefault(predicate: choice => RawValue(choice: choice!.Value) == rawValue);
}
