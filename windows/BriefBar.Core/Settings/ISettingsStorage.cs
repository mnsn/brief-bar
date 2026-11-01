using System.Text.Json.Nodes;

namespace BriefBar.Core.Settings;

/// Where BriefBar keeps its settings, as values by key, so that tests can keep them in memory. The Mac's
/// `SettingsStorage`, which its UserDefaults implement.
public interface ISettingsStorage
{
    /// A copy of the value saved under `key`, or null when there's none: changing it changes nothing saved.
    JsonNode? Read(string key);

    /// Keeps a copy of `value` under `key`, or removes the key for null, and saves it. Returns whether everything kept so
    /// far is saved, to last after BriefBar quits: when it can't be, as on a full disk, it's kept until BriefBar quits,
    /// and the next write, or `Flush`, tries again.
    bool Write(string key, JsonNode? value);

    /// Tries again to save what couldn't be saved. Returns whether everything kept so far is saved.
    bool Flush();
}
