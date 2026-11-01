using System.Text.Json;
using System.Text.Json.Nodes;
using BriefBar.Core.Logging;

namespace BriefBar.Core.Settings;

/// Settings saved as JSON in one file: `%LOCALAPPDATA%\BriefBar\Settings.json` for the app. A file that's missing or
/// can't be read holds nothing, so every source is off (`SourceChoices`). Each change writes the whole file, to a
/// temporary file first, so that a crash never leaves half of one. A write that another program blocks for a moment, as
/// an antivirus scanning the file can, is tried again a few times. One that still fails is logged, and says so: the change
/// stays in memory until BriefBar quits, and the next write, or `Flush`, saves it with everything else.
public sealed class JsonFileSettings : ISettingsStorage
{
    /// How many times a save is tried, the next a little later than the last.
    const int SaveAttempts = 3;
    static readonly TimeSpan retryDelay = TimeSpan.FromMilliseconds(value: 50);
    static readonly JsonSerializerOptions writing = new() { WriteIndented = true };

    readonly Lock gate = new();
    readonly string path;
    readonly JsonObject values;
    /// What's in memory isn't all in the file, as the last save failed.
    bool unsaved;

    public JsonFileSettings(string path)
    {
        this.path = path;
        values = Load(path: path);
    }

    /// `%LOCALAPPDATA%\BriefBar\Settings.json`.
    public static string DefaultPath => Path.Combine(
        path1: Environment.GetFolderPath(folder: Environment.SpecialFolder.LocalApplicationData),
        path2: "BriefBar",
        path3: "Settings.json");

    public JsonNode? Read(string key)
    {
        lock (gate)
        {
            return values[propertyName: key]?.DeepClone();
        }
    }

    public bool Write(string key, JsonNode? value)
    {
        lock (gate)
        {
            if (value is null)
            {
                if (!values.Remove(propertyName: key))
                {
                    return !unsaved;
                }
            }
            else
            {
                values[propertyName: key] = value.DeepClone();
            }
            return Save();
        }
    }

    public bool Flush()
    {
        lock (gate)
        {
            return !unsaved || Save();
        }
    }

    static JsonObject Load(string path)
    {
        try
        {
            if (!File.Exists(path: path) || JsonNode.Parse(json: File.ReadAllText(path: path)) is not JsonObject saved)
            {
                return [];
            }
            KeepWhatCanBeRead(saved: saved);
            return saved;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or ArgumentException)
        {
            Log.Write(line: $"settings: the file can't be read; starting with none");
            return [];
        }
        catch (IOException error)
        {
            Log.Write(error: error, context: $"settings: the file can't be read; starting with none");
            return [];
        }
        catch (UnauthorizedAccessException error)
        {
            Log.Write(error: error, context: $"settings: the file can't be read; starting with none");
            return [];
        }
    }

    /// Leaves out each setting that can't be read in full: one with text .NET can't make a string of, as half of an emoji
    /// written as an escape, or with a name twice in one place. System.Text.Json takes both as it parses, and finds out only
    /// as each part is first needed, so they would otherwise fail a read, or every save after, of everything. The others
    /// are kept. Throws when the settings' own names can't be read: `InvalidOperationException`, or `ArgumentException`
    /// for one that's there twice.
    static void KeepWhatCanBeRead(JsonObject saved)
    {
        foreach (var key in saved.Select(selector: pair => pair.Key).ToList())
        {
            try
            {
                ReadAll(node: saved[propertyName: key]);
            }
            catch (Exception error) when (error is InvalidOperationException or ArgumentException)
            {
                saved.Remove(propertyName: key);
                Log.Write(line: $"settings: a setting can't be read; left out");
            }
        }
    }

    /// Reads every name and string in `node`, which throws as reading it later would.
    static void ReadAll(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject members:
                foreach (var (_, member) in members)
                {
                    ReadAll(node: member);
                }
                break;
            case JsonArray items:
                foreach (var item in items)
                {
                    ReadAll(node: item);
                }
                break;
            case JsonValue value when value.GetValueKind() == JsonValueKind.String:
                _ = value.GetValue<string>();
                break;
            default:
                break;
        }
    }

    /// Writes everything kept, and says whether it could.
    bool Save()
    {
        var temporary = path + ".tmp";
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                if (Path.GetDirectoryName(path: path) is { Length: > 0 } folder)
                {
                    Directory.CreateDirectory(path: folder);
                }
                File.WriteAllText(path: temporary, contents: values.ToJsonString(options: writing));
                File.Move(sourceFileName: temporary, destFileName: path, overwrite: true);
                unsaved = false;
                return true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                if (attempt < SaveAttempts)
                {
                    Thread.Sleep(timeout: retryDelay * attempt);
                    continue;
                }
                Log.Write(error: error, context: $"settings: couldn't save; kept until BriefBar quits, and tried again");
                unsaved = true;
                return false;
            }
        }
    }
}
