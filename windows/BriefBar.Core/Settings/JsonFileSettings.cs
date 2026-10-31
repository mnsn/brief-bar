using System.Text.Json;
using System.Text.Json.Nodes;
using BriefBar.Core.Logging;

namespace BriefBar.Core.Settings;

/// Settings saved as JSON in one file: `%LOCALAPPDATA%\BriefBar\Settings.json` for the app. A file that's missing or
/// can't be read holds nothing, so every source is off (`SourceChoices`). Each change writes the whole file, to a
/// temporary file first, so that a crash never leaves half of one. A write that fails is logged, and the change stays
/// in memory until BriefBar quits.
public sealed class JsonFileSettings : ISettingsStorage
{
    static readonly JsonSerializerOptions writing = new() { WriteIndented = true };

    readonly Lock gate = new();
    readonly string path;
    readonly JsonObject values;

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

    public void Write(string key, JsonNode? value)
    {
        lock (gate)
        {
            if (value is null)
            {
                if (!values.Remove(propertyName: key))
                {
                    return;
                }
            }
            else
            {
                values[propertyName: key] = value.DeepClone();
            }
            Save();
        }
    }

    static JsonObject Load(string path)
    {
        try
        {
            return File.Exists(path: path) && JsonNode.Parse(json: File.ReadAllText(path: path)) is JsonObject saved ? saved : [];
        }
        catch (JsonException)
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

    void Save()
    {
        var temporary = path + ".tmp";
        try
        {
            if (Path.GetDirectoryName(path: path) is { Length: > 0 } folder)
            {
                Directory.CreateDirectory(path: folder);
            }
            File.WriteAllText(path: temporary, contents: values.ToJsonString(options: writing));
            File.Move(sourceFileName: temporary, destFileName: path, overwrite: true);
        }
        catch (IOException error)
        {
            Log.Write(error: error, context: $"settings: couldn't save; kept until BriefBar quits");
        }
        catch (UnauthorizedAccessException error)
        {
            Log.Write(error: error, context: $"settings: couldn't save; kept until BriefBar quits");
        }
    }
}
