using System.Text.Json.Nodes;

namespace BriefBar.Core.Settings;

/// Settings kept in memory only: for tests, which leave nothing behind, and for the demo, which never touches yours. All
/// they promise is memory, so they're always saved.
public sealed class MemorySettings : ISettingsStorage
{
    readonly Lock gate = new();
    readonly Dictionary<string, JsonNode> values = [];

    public JsonNode? Read(string key)
    {
        lock (gate)
        {
            return values.TryGetValue(key: key, value: out var value) ? value.DeepClone() : null;
        }
    }

    public bool Write(string key, JsonNode? value)
    {
        lock (gate)
        {
            if (value is null)
            {
                values.Remove(key: key);
            }
            else
            {
                values[key] = value.DeepClone();
            }
        }
        return true;
    }

    public bool Flush() => true;
}
