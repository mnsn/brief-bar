namespace BriefBar.Core.AzureDevOps;

/// Reading Azure DevOps failed: `Error` says how.
public sealed class ADOException : Exception
{
    public ADOException()
        : this(error: ADOError.Network(message: "Couldn't read Azure DevOps."))
    {
    }

    public ADOException(string message)
        : this(error: ADOError.Network(message: message))
    {
    }

    public ADOException(string message, Exception innerException)
        : base(message: message, innerException: innerException)
    {
        Error = ADOError.Network(message: message);
    }

    public ADOException(ADOError error, Exception? innerException = null)
        : base(message: error?.Description, innerException: innerException)
    {
        ArgumentNullException.ThrowIfNull(argument: error);
        Error = error;
    }

    public ADOError Error { get; }
}
