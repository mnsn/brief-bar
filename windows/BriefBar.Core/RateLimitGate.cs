namespace BriefBar.Core;

/// Remembers how long Azure DevOps or GitHub asked BriefBar to wait, so that no request goes out to it before then: the
/// time it gave, or a minute when it asked to slow down without saying. Each client has its own. The Mac's
/// `RateLimitGate`, which AzureDevOpsCore and GitHubCore each have.
internal sealed class RateLimitGate(TimeProvider time)
{
    readonly Lock gate = new();
    DateTimeOffset notBefore = DateTimeOffset.MinValue;

    /// Holds requests back for `wait` from now, unless they're held longer already.
    public void Hold(TimeSpan wait)
    {
        lock (gate)
        {
            var until = time.GetUtcNow() + wait;
            if (until > notBefore)
            {
                notBefore = until;
            }
        }
    }

    /// How long requests are held back still, or null when they aren't.
    public TimeSpan? RemainingWait()
    {
        lock (gate)
        {
            var wait = notBefore - time.GetUtcNow();
            return wait > TimeSpan.Zero ? wait : null;
        }
    }
}
