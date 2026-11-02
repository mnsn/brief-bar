using System.Text;
using BriefBar.Core.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// The Mac's `LevelDBManifestTests`: which tables and logs LevelDB's MANIFEST says the database has, as LevelDB reads it.
public sealed class LevelDBManifestTests
{
    [Fact]
    public void AppliesEachEditInOrder()
    {
        // Log 3 flushed to table 5, then log 6 to table 7; compaction merged both into table 9, then moved it a level down.
        var manifest = ManifestWriter.Manifest(
            ManifestWriter.Edit(comparator: "idb_cmp1", logNumber: 3, nextFile: 4, lastSequence: 0),
            ManifestWriter.Edit(logNumber: 6, nextFile: 7, lastSequence: 3, added: [5]),
            ManifestWriter.Edit(logNumber: 8, nextFile: 9, lastSequence: 6, added: [7]),
            ManifestWriter.Edit(nextFile: 10, lastSequence: 7, deleted: [5, 7], added: [9]),
            [.. ManifestWriter.Edit(deleted: [9]), .. ManifestWriter.Edit(added: [9], level: 1)]);

        var version = LevelDBManifest.Parse(bytes: manifest);

        Assert.Equal(expected: new HashSet<ulong> { 9 }, actual: version.Tables);
        Assert.Equal(expected: 8UL, actual: version.LogNumber);
        Assert.Equal(expected: 0UL, actual: version.PrevLogNumber);
    }

    /// LevelDB applies an edit's deletions, then its additions, whatever their order in it.
    [Fact]
    public void RemovesAnEditsTablesBeforeAddingItsOwn()
    {
        var manifest = ManifestWriter.Manifest(
            ManifestWriter.Edit(logNumber: 1, nextFile: 6, lastSequence: 1, added: [4, 5]),
            [.. ManifestWriter.Edit(added: [5]), .. ManifestWriter.Edit(deleted: [4, 5])]);

        Assert.Equal(expected: new HashSet<ulong> { 5 }, actual: LevelDBManifest.Parse(bytes: manifest).Tables);
    }

    /// The logs LevelDB replays as it opens the database: from its log number on, and the older one it may still need.
    [Fact]
    public void KeepsTheLogsLevelDBReplays()
    {
        var manifest = ManifestWriter.Manifest(
            [.. ManifestWriter.Edit(logNumber: 8, nextFile: 10, lastSequence: 1), .. Encodings.Varint(value: 9), .. Encodings.Varint(value: 6)]);

        var version = LevelDBManifest.Parse(bytes: manifest);

        Assert.Equal(expected: 6UL, actual: version.PrevLogNumber);
        Assert.Equal(expected: [false, true, false, true, true], actual: new ulong[] { 5, 6, 7, 8, 9 }.Select(selector: log => version.IsLiveLog(number: log)));
    }

    /// LevelDB writes an edit as one record, at the end: one that isn't all there yet is one it's still writing.
    [Fact]
    public void LeavesOutAnEditStillBeingWritten()
    {
        var first = ManifestWriter.Manifest(ManifestWriter.Edit(comparator: "idb_cmp1", logNumber: 3, nextFile: 6, lastSequence: 0, added: [5]));
        var whole = ManifestWriter.Manifest(
            ManifestWriter.Edit(comparator: "idb_cmp1", logNumber: 3, nextFile: 6, lastSequence: 0, added: [5]),
            ManifestWriter.Edit(logNumber: 7, nextFile: 9, lastSequence: 4, deleted: [5], added: [8]));

        foreach (var cut in new[] { first.Length + 3, whole.Length - 1 })
        {
            var version = LevelDBManifest.Parse(bytes: whole[..cut]);
            Assert.Equal(expected: new HashSet<ulong> { 5 }, actual: version.Tables);
            Assert.Equal(expected: 3UL, actual: version.LogNumber);
        }
    }

    /// What LevelDB refuses to open the database with, BriefBar doesn't go by either.
    [Fact]
    public void RefusesWhatLevelDBRefuses()
    {
        var complete = ManifestWriter.Edit(comparator: "idb_cmp1", logNumber: 3, nextFile: 6, lastSequence: 0);
        void Refused(params byte[][] edits) => Assert.Throws<FormatErrorException>(testCode: () => LevelDBManifest.Parse(bytes: ManifestWriter.Manifest(edits: edits)));

        // An edit it doesn't know, as a large value reference, which LevelDB no longer has.
        Refused(complete, [.. Encodings.Varint(value: 8), .. Encodings.Varint(value: 1)]);
        Refused(ManifestWriter.Edit(nextFile: 6, lastSequence: 0));
        Refused(ManifestWriter.Edit(logNumber: 3, lastSequence: 0));
        Refused(ManifestWriter.Edit(logNumber: 3, nextFile: 6));
        Refused(complete, ManifestWriter.Edit(added: [5], level: 7));
        // A table without its keys, all in one record.
        Refused(complete, ManifestWriter.Edit(added: [5])[..^4]);
        // A record whose checksum doesn't match, with another after it.
        var damaged = ManifestWriter.Manifest(complete, ManifestWriter.Edit(added: [5]), ManifestWriter.Edit(added: [6]));
        damaged[LevelDBLog.HeaderSize + complete.Length + LevelDBLog.HeaderSize + 1] ^= 0xFF;
        Assert.Throws<FormatErrorException>(testCode: () => LevelDBManifest.Parse(bytes: damaged));
    }

    /// Microsoft Edge's, in the fixture: as LevelDB creates a database, with no tables, and its log number 0, which keeps
    /// every log.
    [Fact]
    public void ReadsTheFixturesManifest()
    {
        var current = File.ReadAllBytes(path: Path.Combine(path1: Fixture.LevelDB, path2: LevelDBManifest.CurrentFile));
        var name = LevelDBManifest.Name(current: current);

        var version = LevelDBManifest.Parse(bytes: File.ReadAllBytes(path: Path.Combine(path1: Fixture.LevelDB, path2: name)));

        Assert.Equal(expected: "MANIFEST-000001", actual: name);
        Assert.Empty(collection: version.Tables);
        Assert.True(condition: version.IsLiveLog(number: 3));
    }

    [Fact]
    public void ReadsOnlyAManifestsNameFromCurrent()
    {
        Assert.Equal(expected: "MANIFEST-000012", actual: LevelDBManifest.Name(current: Encoding.ASCII.GetBytes(s: "MANIFEST-000012\n")));
        foreach (var current in new[] { string.Empty, "MANIFEST-000012", "MANIFEST-000012\r\n", "MANIFEST-\n", "MANIFEST-12a\n", "..\\MANIFEST-000012\n", "LOG\n" })
        {
            Assert.Throws<FormatErrorException>(testCode: () => LevelDBManifest.Name(current: Encoding.ASCII.GetBytes(s: current)));
        }
    }
}
