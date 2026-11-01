namespace BriefBar.Core.Copilot;

/// The Copilot app's database couldn't be opened or read: SQLite's error, in a sentence that says so. The Mac's
/// `AppDatabaseError`.
public sealed class AppDatabaseException : Exception
{
    public AppDatabaseException()
    {
    }

    public AppDatabaseException(string message)
        : base(message: message)
    {
    }

    public AppDatabaseException(string message, Exception innerException)
        : base(message: message, innerException: innerException)
    {
    }

    /// `detail` is SQLite's own message, such as "unable to open database file", and `code` its result code.
    public AppDatabaseException(AppDatabaseFailure failure, string detail, int code, Exception? innerException)
        : base(
            message: failure == AppDatabaseFailure.Open
                ? "Could not open Copilot database: " + detail
                : "Copilot database query failed: " + detail,
            innerException: innerException)
    {
        Failure = failure;
        Code = code & 0xFF;
    }

    public AppDatabaseFailure Failure { get; }

    /// SQLite's primary result code.
    public int Code { get; }
}
