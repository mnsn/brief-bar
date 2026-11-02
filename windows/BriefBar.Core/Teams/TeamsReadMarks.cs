using System.Security.Cryptography;
using System.Text.Json;
using BriefBar.Core.Logging;

namespace BriefBar.Core.Teams;

/// The chats you marked read in BriefBar, each up to the message it was read to and when, kept by ID only until Teams'
/// own marker passes it and the chat isn't marked unread in Teams from before then: Mark as Read can't change Teams.
/// Saved in `%LOCALAPPDATA%\BriefBar\Teams\read`, sealed for your Windows account (`ISecretProtector`), as the Mac seals
/// its unread chats with a key in your keychain. Not thread-safe: `TeamsSource` uses it under its lock.
public sealed class TeamsReadMarks
{
    readonly string? path;
    readonly ISecretProtector? protector;
    readonly Dictionary<string, TeamsReadMark> marks = new(comparer: StringComparer.Ordinal);
    bool deleted;

    public TeamsReadMarks(string path, ISecretProtector protector)
    {
        ArgumentException.ThrowIfNullOrEmpty(argument: path);
        ArgumentNullException.ThrowIfNull(argument: protector);
        this.path = path;
        this.protector = protector;
    }

    TeamsReadMarks()
    {
    }

    /// Marks kept in memory only, as the demo's are: nothing is read or saved.
    public static TeamsReadMarks InMemory() => new();

    /// `%LOCALAPPDATA%\BriefBar\Teams\read`.
    public static string DefaultPath => Path.Combine(
        path1: Environment.GetFolderPath(folder: Environment.SpecialFolder.LocalApplicationData),
        path2: "BriefBar",
        path3: "Teams",
        path4: "read");

    /// How far each chat was marked read, and when, by chat.
    public IReadOnlyDictionary<string, TeamsReadMark> Marks => marks;

    /// Reads what was saved. A file that can't be opened, as one sealed for someone else or damaged, is deleted.
    public void Load()
    {
        marks.Clear();
        if (path is null || protector is null)
        {
            return;
        }
        byte[] sealedData;
        try
        {
            if (!File.Exists(path: path))
            {
                return;
            }
            sealedData = File.ReadAllBytes(path: path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Log.Write(error: error, context: $"teams: couldn't read the chats marked read");
            return;
        }
        try
        {
            var saved = JsonSerializer.Deserialize<Dictionary<string, TeamsReadMark>>(utf8Json: protector.Unprotect(sealedData: sealedData));
            foreach (var (chat, mark) in saved ?? [])
            {
                if (ConversationIds.IsValid(id: chat) && mark is { UpTo: > 0 })
                {
                    marks[chat] = mark;
                }
            }
        }
        catch (Exception error) when (error is CryptographicException or JsonException)
        {
            Log.Write(error: error, context: $"teams: couldn't open the chats marked read; deleting them");
            Remove();
        }
    }

    /// Marks `chat` read up to `messageId` at `at`, which also reads a Mark as unread that Teams has from before then, and
    /// saves it.
    public void Mark(string chat, long messageId, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(argument: chat);
        if (deleted)
        {
            return;
        }
        var mark = marks.TryGetValue(key: chat, value: out var known)
            ? new TeamsReadMark(UpTo: Math.Max(val1: known.UpTo, val2: messageId), At: known.At > at ? known.At : at)
            : new TeamsReadMark(UpTo: messageId, At: at);
        if (mark == known)
        {
            return;
        }
        marks[chat] = mark;
        Save();
    }

    /// Forgets the marks that have nothing left to do, and, with `dropAbsent`, those of chats that aren't in `chats`, and
    /// saves what's left. A mark is done once Teams' own marker has passed it and Teams doesn't have the chat marked unread
    /// from before it. Only a read of all of Teams' data says a chat is gone: one that missed something may only have
    /// missed that chat.
    public void Prune(IEnumerable<TeamsChat> chats, bool dropAbsent)
    {
        ArgumentNullException.ThrowIfNull(argument: chats);
        if (marks.Count == 0)
        {
            return;
        }
        var byId = chats.ToDictionary(keySelector: chat => chat.Id, comparer: StringComparer.Ordinal);
        var passed = marks
            .Where(predicate: mark => byId.TryGetValue(key: mark.Key, value: out var chat)
                ? (chat.Marker?.MessageId ?? 0) >= mark.Value.UpTo && !(chat.MarkedUnread is { } markedUnread && mark.Value.Dismisses(markedUnread: markedUnread))
                : dropAbsent)
            .Select(selector: mark => mark.Key)
            .ToList();
        if (passed.Count == 0)
        {
            return;
        }
        foreach (var chat in passed)
        {
            marks.Remove(key: chat);
        }
        Save();
    }

    /// Deletes what was saved, and the folder if that leaves it empty, as turning Teams off does; nothing is saved from
    /// then on.
    public void Delete()
    {
        deleted = true;
        marks.Clear();
        Remove();
    }

    /// Writes the marks, sealed, atomically; deletes the file when there are none.
    void Save()
    {
        if (deleted || path is null || protector is null)
        {
            return;
        }
        if (marks.Count == 0)
        {
            Remove();
            return;
        }
        try
        {
            var folder = Path.GetDirectoryName(path: path)!;
            Directory.CreateDirectory(path: folder);
            var sealedData = protector.Protect(data: JsonSerializer.SerializeToUtf8Bytes(value: marks));
            var temporary = path + ".tmp";
            File.WriteAllBytes(path: temporary, bytes: sealedData);
            File.Move(sourceFileName: temporary, destFileName: path, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            // They stay in memory until BriefBar quits.
            Log.Write(error: error, context: $"teams: couldn't save the chats marked read");
        }
    }

    void Remove()
    {
        var folder = Path.GetDirectoryName(path: path);
        if (path is null || folder is null)
        {
            return;
        }
        try
        {
            // Nothing was saved yet: there's nothing to delete, and deleting a file in a missing folder fails.
            if (!Directory.Exists(path: folder))
            {
                return;
            }
            File.Delete(path: path);
            File.Delete(path: path + ".tmp");
            if (!Directory.EnumerateFileSystemEntries(path: folder).Any())
            {
                Directory.Delete(path: folder);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Log.Write(error: error, context: $"teams: couldn't delete the chats marked read");
        }
    }
}
