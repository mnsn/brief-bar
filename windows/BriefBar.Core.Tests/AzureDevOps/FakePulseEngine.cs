using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// An engine a test drives: it hands over what the test says, when it says, and notes what the source asks of it. Its
/// loop runs until it's stopped, or ends with an error a test makes up (`Fail`).
internal sealed class FakePulseEngine(Action<PulseSnapshot> onChange) : IPulseEngine
{
    readonly Lock gate = new();
    readonly TaskCompletionSource loop = new(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
    readonly List<string> calls = [];
    PulseEngineConfiguration? configuration;
    IReadOnlySet<PRKey> linked = new HashSet<PRKey>();

    /// "start", "stop", "refresh", "configure" and "link", in the order they happened.
    public IReadOnlyList<string> Calls
    {
        get
        {
            lock (gate)
            {
                return [.. calls];
            }
        }
    }

    public PulseEngineConfiguration? Configuration
    {
        get
        {
            lock (gate)
            {
                return configuration;
            }
        }
    }

    public IReadOnlySet<PRKey> Linked
    {
        get
        {
            lock (gate)
            {
                return linked;
            }
        }
    }

    public Task Start()
    {
        Note(call: "start");
        return loop.Task;
    }

    public Task StopAsync()
    {
        Note(call: "stop");
        loop.TrySetResult();
        return Task.CompletedTask;
    }

    public void Refresh() => Note(call: "refresh");

    public void SetConfiguration(PulseEngineConfiguration newConfiguration)
    {
        lock (gate)
        {
            configuration = newConfiguration;
        }
        Note(call: "configure");
    }

    public void SetLinkedPullRequests(IReadOnlySet<PRKey> keys)
    {
        lock (gate)
        {
            linked = keys;
        }
        Note(call: "link");
    }

    public void Publish(PulseSnapshot snapshot) => onChange(obj: snapshot);

    /// Its loop ends with an error BriefBar doesn't expect.
    public void Fail() => loop.TrySetException(exception: new InvalidOperationException(message: "Made-up failure."));

    public void Dispose()
    {
    }

    void Note(string call)
    {
        lock (gate)
        {
            calls.Add(item: call);
        }
    }
}
