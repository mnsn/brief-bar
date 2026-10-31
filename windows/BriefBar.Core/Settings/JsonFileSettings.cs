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
