using System.Text.Json;
using System.Text.Json.Nodes;
using BriefBar.Core.Logging;
using BriefBar.Core.Settings;

namespace BriefBar.Core;

/// The sources you turned on, saved in BriefBar's settings.
///
/// Turning a source on is the only consent it gets. A source is on only while this holds your consent to what it reads:
/// a missing or unreadable record, a source that an update adds, or one this version doesn't know is off. Nothing but
/// `TurnOn` adds consent. The Mac's `SourceChoices`.
public sealed class SourceChoices
{
    public const string SettingsKey = "sources";

    /// By source's raw name. Names that this version doesn't know are kept as they are, for a later version, and ignored.
    readonly Dictionary<string, SourceConsent> consents;

    public SourceChoices()
    {
        consents = new Dictionary<string, SourceConsent>(comparer: StringComparer.Ordinal);
    }

    public IReadOnlyDictionary<string, SourceConsent> Consents => consents;

    /// Whether the source is on, given the version of its description of what it reads.
    public SourceState State(SourceId source, int version) =>
        !consents.TryGetValue(key: SourceIds.RawValue(source: source), value: out var consent)
            ? SourceState.Off
            : consent.Version >= version ? SourceState.On : SourceState.NeedsReview;

    /// Turns the source on, with your consent to the version of its description you saw.
    public void TurnOn(SourceId source, int version, DateTimeOffset date) =>
        consents[SourceIds.RawValue(source: source)] = new SourceConsent(Version: version, Date: date);

    public void TurnOff(SourceId source) => consents.Remove(key: SourceIds.RawValue(source: source));

    /// What's saved, or nothing on when there's nothing saved or it can't be read. A consent that can't be read is left
    /// out, so its source is off; when the sources' names can't be, as text .NET can't make a string of, none are on.
    public static SourceChoices Load(ISettingsStorage settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        var choices = new SourceChoices();
        try
        {
            if (settings.Read(key: SettingsKey) is not JsonObject saved || saved["consents"] is not JsonObject consents)
            {
                return choices;
            }
            foreach (var (name, node) in consents)
            {
                if (ConsentFrom(node: node) is { } consent)
                {
                    choices.consents[name] = consent;
                }
            }
            return choices;
        }
        catch (InvalidOperationException)
        {
            // A name System.Text.Json can't decode, as half of an emoji written as an escape, which it finds only now.
            Log.Write(line: $"sources: the choices saved can't be read; every source is off");
            return new SourceChoices();
        }
    }

    /// Saves your choices; returns whether everything is saved, to last after BriefBar quits (`ISettingsStorage.Write`).
    public bool Save(ISettingsStorage settings)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        var saved = new JsonObject();
        foreach (var (name, consent) in consents.OrderBy(keySelector: pair => pair.Key, comparer: StringComparer.Ordinal))
        {
            saved[propertyName: name] = new JsonObject
            {
                ["version"] = consent.Version,
                ["date"] = consent.Date.UtcDateTime.ToString(format: "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", provider: System.Globalization.CultureInfo.InvariantCulture),
            };
        }
        return settings.Write(key: SettingsKey, value: new JsonObject { ["consents"] = saved });
    }

    /// One source's consent, or null when it can't be read, as for a date .NET can't make a string of.
    static SourceConsent? ConsentFrom(JsonNode? node)
    {
        try
        {
            return node is JsonObject consent
                && consent["version"] is JsonValue version && version.GetValueKind() == JsonValueKind.Number && version.TryGetValue(value: out int number)
                && consent["date"] is JsonValue date && date.TryGetValue(value: out string? text) && Timestamp.Parse(text: text) is { } when
                    ? new SourceConsent(Version: number, Date: when)
                    : null;
        }
        catch (InvalidOperationException)
        {
            // Half of an emoji, written as an escape: System.Text.Json reads it, but can't decode it.
            return null;
        }
    }
}
