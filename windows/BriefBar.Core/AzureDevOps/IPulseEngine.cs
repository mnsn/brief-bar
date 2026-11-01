namespace BriefBar.Core.AzureDevOps;

/// What `AzureDevOpsSource` runs to read your pull requests: `PulseEngine`, or the demo's made-up one.
public interface IPulseEngine : IDisposable
{
    /// Reads now, then on every interval, until stopped; the task ends with an error only for one BriefBar doesn't expect.
    Task Start();

    /// Stops, waiting for a read under way to stop.
    Task StopAsync();

    /// Reads as soon as it can.
    void Refresh();

    void SetConfiguration(PulseEngineConfiguration newConfiguration);

    /// The pull requests you watch, to read by their links.
    void SetLinkedPullRequests(IReadOnlySet<PRKey> keys);
}
