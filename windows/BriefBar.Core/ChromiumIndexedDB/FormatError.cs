namespace BriefBar.Core.ChromiumIndexedDB;

/// Why bytes couldn't be read as the format they should be in, and in what part of it, such as "corrupt varint". It never
/// holds any of the data. The Mac's `FormatError`.
public readonly record struct FormatError(FormatErrorKind Kind, string What)
{
    public static FormatError Truncated { get; } = new(Kind: FormatErrorKind.Truncated, What: string.Empty);

    public static FormatError Corrupt(string what) => new(Kind: FormatErrorKind.Corrupt, What: what);

    public static FormatError Unsupported(string what) => new(Kind: FormatErrorKind.Unsupported, What: what);

    /// "truncated", "corrupt varint", "unsupported V8 version", as the Mac says them.
    public override string ToString() => Kind switch
    {
        FormatErrorKind.Truncated => "truncated",
        FormatErrorKind.Corrupt => "corrupt " + What,
        _ => "unsupported " + What,
    };
}
