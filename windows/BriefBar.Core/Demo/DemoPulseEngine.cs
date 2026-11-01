using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Demo;

/// An engine that reads nothing: it hands over `AzureDevOpsDemoData`'s made-up pull requests as it starts, and again when
/// asked to read again, on the thread pool, so `AzureDevOpsSource` shows them as it would Azure DevOps'.
public sealed class DemoPulseEngine(DateTimeOffset madeAt, Action<PulseSnapshot> onChange) : IPulseEngine
{
    readonly PulseSnapshot snapshot = AzureDevOpsDemoData.Snapshot(now: madeAt);

    public Task Start() => Task.Run(action: () => onChange(obj: snapshot));

    public Task StopAsync() => Task.CompletedTask;

    public void Refresh() => _ = Task.Run(action: () => onChange(obj: snapshot));

    /// The made-up pull requests are the same whatever the settings say.
    public void SetConfiguration(PulseEngineConfiguration newConfiguration)
    {
    }

    /// It watches no pull request.
    public void SetLinkedPullRequests(IReadOnlySet<PRKey> keys)
    {
    }

    public void Dispose()
    {
    }
}
