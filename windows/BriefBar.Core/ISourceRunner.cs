namespace BriefBar.Core;

/// What runs the sources that are on: the app's, which shows them.
public interface ISourceRunner
{
    /// Adds `source` and starts it.
    Task AddAsync(ISectionSource source);

    /// Takes the source `source` off the bar and returns it, still running, for the caller to stop; or null when it
    /// isn't running.
    ISectionSource? Remove(SourceId source);
}
