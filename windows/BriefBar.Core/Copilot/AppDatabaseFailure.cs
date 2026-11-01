namespace BriefBar.Core.Copilot;

/// What went wrong with the Copilot app's database.
public enum AppDatabaseFailure
{
    /// It couldn't be opened, as when it isn't there.
    Open,

    /// A query failed, as when the app changed its schema.
    Query,
}
