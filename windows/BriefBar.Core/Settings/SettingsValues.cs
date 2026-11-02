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

    public static string Text(this ISettingsStorage settings, string key)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        return settings.Read(key: key) is JsonValue value && value.TryGetValue(value: out string? text) ? text : string.Empty;
    }

    /// Saves `value` under `key`; returns whether everything is saved (`ISettingsStorage.Write`).
    public static bool SetText(this ISettingsStorage settings, string key, string value)
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
        return settings.Read(key: key) is JsonObject saved ? DatesFrom(node: saved) : new Dictionary<string, DateTimeOffset>(comparer: StringComparer.Ordinal);
    }

    /// Saves `dates` under `key`, as `Dates` reads them; returns whether everything is saved (`ISettingsStorage.Write`).
    public static bool SetDates(this ISettingsStorage settings, string key, IReadOnlyDictionary<string, DateTimeOffset> dates)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        return settings.Write(key: key, value: DatesNode(dates: dates));
    }

    /// A time as it's saved: seconds since 1970, as the Mac saves times, to the tick, so that it reads back exactly as it
    /// was. A double can't hold every tick of today's dates, and a seen time that came back a tick early would make the
    /// comment it was set to new again.
    public static JsonValue DateNode(DateTimeOffset date) =>
        JsonValue.Create(value: (date - DateTimeOffset.UnixEpoch).Ticks / (decimal)TimeSpan.TicksPerSecond);

    /// The time `node` saved, as `DateNode` saves it; null for anything else, or a time outside the years 1 to 9999, which
    /// is all a DateTimeOffset holds.
    public static DateTimeOffset? DateFrom(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(value: out decimal seconds) && seconds is > -62_135_596_800m and < 253_402_300_799m
            ? DateTimeOffset.UnixEpoch.AddTicks(ticks: (long)decimal.Round(d: seconds * TimeSpan.TicksPerSecond))
            : null;

    /// Names and times, as `Dates` reads them, the names in order.
    public static JsonObject DatesNode(IReadOnlyDictionary<string, DateTimeOffset> dates)
    {
        ArgumentNullException.ThrowIfNull(argument: dates);
        var saved = new JsonObject();
        foreach (var (name, date) in dates.OrderBy(keySelector: pair => pair.Key, comparer: StringComparer.Ordinal))
        {
            saved[propertyName: name] = DateNode(date: date);
        }
        return saved;
    }

    /// The names and times `node` saved, without entries of another kind, and without any when their names can't be read,
    /// as text .NET can't make a string of.
    public static Dictionary<string, DateTimeOffset> DatesFrom(JsonObject node)
    {
        ArgumentNullException.ThrowIfNull(argument: node);
        var dates = new Dictionary<string, DateTimeOffset>(comparer: StringComparer.Ordinal);
        try
        {
            foreach (var (name, value) in node)
            {
                if (DateFrom(node: value) is { } date)
                {
                    dates[name] = date;
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
}
