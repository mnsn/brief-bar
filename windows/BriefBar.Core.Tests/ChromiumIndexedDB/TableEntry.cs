namespace BriefBar.Core.Tests.ChromiumIndexedDB;

/// A write in a made-up LevelDB table: a key's value, or its deletion (`Value` null).
internal sealed record TableEntry(byte[] Key, ulong Sequence, byte[]? Value);
