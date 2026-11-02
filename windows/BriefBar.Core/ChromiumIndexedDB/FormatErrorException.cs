namespace BriefBar.Core.ChromiumIndexedDB;

/// Bytes couldn't be read as the format they should be in: `Error` says why, without any of the data.
public sealed class FormatErrorException : Exception
{
    public FormatErrorException()
        : this(error: FormatError.Truncated)
    {
    }

    public FormatErrorException(string message)
        : base(message: message)
    {
        Error = FormatError.Corrupt(what: "data");
    }

    public FormatErrorException(string message, Exception innerException)
        : base(message: message, innerException: innerException)
    {
        Error = FormatError.Corrupt(what: "data");
    }

    public FormatErrorException(FormatError error)
        : base(message: error.ToString())
    {
        Error = error;
    }

    public FormatError Error { get; }

    public static FormatErrorException Truncated() => new(error: FormatError.Truncated);

    public static FormatErrorException Corrupt(string what) => new(error: FormatError.Corrupt(what: what));

    public static FormatErrorException Unsupported(string what) => new(error: FormatError.Unsupported(what: what));
}
