using System.Text.Json.Nodes;

namespace BriefBar.Core.Settings;

/// Where BriefBar keeps its settings, as values by key, so that tests can keep them in memory. The Mac's
/// `SettingsStorage`, which its UserDefaults implement.
public interface ISettingsStorage
{
    /// A copy of the value saved under `key`, or null when there's none: changing it changes nothing saved.
    JsonNode? Read(string key);

    /// Saves a copy of `value` under `key`, or removes the key for null.
    void Write(string key, JsonNode? value);
}
