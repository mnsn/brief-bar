using System.Globalization;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Presentation;

/// BriefBar's appearance, in its settings: what the bar shows behind its words, and the color of your own it shows
/// when you choose one. Safe to use from any thread.
public sealed class AppearanceSettings
{
    public const string BarBackgroundKey = "interface.barBackground";
    public const string BarColorKey = "interface.barColor";

    readonly Lock gate = new();
    readonly ISettingsStorage settings;
    BarBackground barBackground;
    uint? barColor;

    public AppearanceSettings(ISettingsStorage settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        this.settings = settings;
        barBackground = BackgroundOf(saved: settings.Text(key: BarBackgroundKey));
        barColor = ColorOf(saved: settings.Text(key: BarColorKey));
    }

    /// One of them changed, on whichever thread changed it.
    public event EventHandler? Changed;

    /// What the bar shows behind its words: Automatic until you choose otherwise.
    public BarBackground BarBackground
    {
        get
        {
            lock (gate)
            {
                return barBackground;
            }
        }
        set
        {
            lock (gate)
            {
                if (value == barBackground || !Enum.IsDefined(value: value))
                {
                    return;
                }
                barBackground = value;
                settings.SetText(key: BarBackgroundKey, value: NameOf(background: value));
            }
            Changed?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    /// The color of your own, ARGB, as you chose it, with how see-through it is; null until you choose one.
    public uint? BarColor
    {
        get
        {
            lock (gate)
            {
                return barColor;
            }
        }
        set
        {
            lock (gate)
            {
                if (value == barColor || value is not { } color)
                {
                    return;
                }
                barColor = color;
                settings.SetText(key: BarColorKey, value: "#" + color.ToString(format: "X8", provider: CultureInfo.InvariantCulture));
            }
            Changed?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    static BarBackground BackgroundOf(string saved) => saved switch
    {
        "taskbar" => BarBackground.LikeTheTaskbar,
        "color" => BarBackground.CustomColor,
        _ => BarBackground.Automatic,
    };

    static string NameOf(BarBackground background) => background switch
    {
        BarBackground.LikeTheTaskbar => "taskbar",
        BarBackground.CustomColor => "color",
        _ => "automatic",
    };

    /// "#AARRGGBB", as saved; null for anything else.
    static uint? ColorOf(string saved) =>
        saved.Length == 9 && saved[0] == '#'
        && uint.TryParse(s: saved.AsSpan(start: 1), style: NumberStyles.AllowHexSpecifier, provider: CultureInfo.InvariantCulture, result: out var color)
            ? color
            : null;
}
