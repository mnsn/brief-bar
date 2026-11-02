namespace BriefBar.Core.Tests.AzureDevOps;

/// Holds one of the Azure CLI's runs for a directory, the first unless said (`run`), until let go, with the token it had
/// when asked: someone else may sign in meanwhile. As the Swift tests' `HeldDirectory`.
internal sealed class HeldDirectory(string tenant, int run = 1)
{
    readonly Lock gate = new();
    readonly TaskCompletionSource released = new(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
    int runs;
    bool holding;

    public bool IsHolding
    {
        get
        {
            lock (gate)
            {
                return holding;
            }
        }
    }

    /// Holds the run for `asked`, the directory a run is for, if it's the one to hold.
    public Task HoldAsync(string asked)
    {
        lock (gate)
        {
            if (asked != tenant || ++runs != run)
            {
                return Task.CompletedTask;
            }
            holding = true;
        }
        return released.Task;
    }

    public void Release()
    {
        lock (gate)
        {
            holding = false;
        }
        released.TrySetResult();
    }
}
