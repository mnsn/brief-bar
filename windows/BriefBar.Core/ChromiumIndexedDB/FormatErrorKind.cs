namespace BriefBar.Core.ChromiumIndexedDB;

/// Why bytes couldn't be read as the format they should be in.
public enum FormatErrorKind
{
    /// The data ends before what it says it holds.
    Truncated,

    /// The data contradicts the format.
    Corrupt,

    /// A valid form that BriefBar doesn't read, such as a newer version.
    Unsupported,
}
