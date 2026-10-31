namespace BriefBar.Core;

/// What runs the sources that are on: the app's, which shows them.
public interface ISourceRunner
{
    /// Adds `source` and starts it.
    Task AddAsync(ISectionSource source);

    /// Stops the source `source` and removes it, returning it, stopped; or null when it isn't running.
    Task<ISectionSource?> RemoveAsync(SourceId source);
}
