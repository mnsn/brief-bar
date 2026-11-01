using System.Text.Json;
using System.Text.Json.Nodes;

namespace BriefBar.Core.Settings;

/// Reading and writing settings' values of each kind, as UserDefaults does on the Mac: a value that's missing, or of
/// another kind, reads as false, 0 or empty.
public static class SettingsValues
{
    public static bool Bool(this ISettingsStorage settings, string key)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        return settings.Read(key: key) is JsonValue value && value.GetValueKind() == JsonValueKind.True;
    }

    /// Saves `value` under `key`; returns whether everything is saved (`ISettingsStorage.Write`).
    public static bool SetBool(this ISettingsStorage settings, string key, bool value)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        return settings.Write(key: key, value: JsonValue.Create(value: value));
    }

    public static int Number(this ISettingsStorage settings, string key)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        return settings.Read(key: key) is JsonValue value && value.TryGetValue(value: out int number) ? number : 0;
    }

    /// Saves `value` under `key`; returns whether everything is saved (`ISettingsStorage.Write`).
    public static bool SetNumber(this ISettingsStorage settings, string key, int value)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        return settings.Write(key: key, value: JsonValue.Create(value: value));
    }

    /// A map of names to times, saved as seconds since 1970, as the Mac saves them; entries of another kind are left
    /// out, and all of them when their names can't be read, as text .NET can't make a string of.
    public static Dictionary<string, DateTimeOffset> Dates(this ISettingsStorage settings, string key)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        var dates = new Dictionary<string, DateTimeOffset>(comparer: StringComparer.Ordinal);
        if (settings.Read(key: key) is not JsonObject saved)
        {
            return dates;
        }
        try
        {
            foreach (var (name, node) in saved)
            {
                // Within the years 1 to 9999, which is all a DateTimeOffset holds.
                if (node is JsonValue value && value.TryGetValue(value: out double seconds) && double.IsFinite(d: seconds)
                    && seconds is > -62_135_596_800 and < 253_402_300_799)
                {
                    dates[name] = DateTimeOffset.UnixEpoch.AddTicks(ticks: (long)Math.Round(a: seconds * TimeSpan.TicksPerSecond));
                }
            }
        }
        catch (InvalidOperationException)
        {
            // A name System.Text.Json can't decode, as half of an emoji written as an escape, which it finds only now.
            dates.Clear();
        }
        return dates;
    }

    /// Saves `dates` under `key`, as `Dates` reads them; returns whether everything is saved (`ISettingsStorage.Write`).
    public static bool SetDates(this ISettingsStorage settings, string key, IReadOnlyDictionary<string, DateTimeOffset> dates)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: dates);
        var saved = new JsonObject();
        foreach (var (name, date) in dates.OrderBy(keySelector: pair => pair.Key, comparer: StringComparer.Ordinal))
        {
            saved[propertyName: name] = JsonValue.Create(value: (date - DateTimeOffset.UnixEpoch).Ticks / (double)TimeSpan.TicksPerSecond);
        }
        return settings.Write(key: key, value: saved);
    }
}
