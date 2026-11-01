namespace BriefBar.Core.AzureDevOps;

/// Remembers how long Azure DevOps asked BriefBar to wait (`Retry-After`), so that no request goes out before then. The
/// Mac's `RateLimitGate`.
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
