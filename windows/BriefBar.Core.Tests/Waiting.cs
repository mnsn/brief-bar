namespace BriefBar.Core.Tests;

/// Waiting, in tests, for what a source does on other threads: its next change, or a condition, for `Limit` at most.
internal static class Waiting
{
    /// How long a test waits for what it expects before it fails.
    public static TimeSpan Limit { get; } = TimeSpan.FromSeconds(value: 10);

    /// Completes the next time `source` says it changed.
    public static Task NextChange(ISectionSource source)
    {
        ArgumentNullException.ThrowIfNull(argument: source);
        var next = new TaskCompletionSource(creationOptions: TaskCreationOptions.RunContinuationsAsynchronously);
        void Changed(object? sender, EventArgs e)
        {
            source.Changed -= Changed;
            next.TrySetResult();
        }
        source.Changed += Changed;
        return next.Task;
    }

    /// Returns once `condition` holds, looking every 10 milliseconds; fails the test when it doesn't within `Limit`.
    public static async Task Until(Func<bool> condition)
    {
        ArgumentNullException.ThrowIfNull(argument: condition);
        var deadline = DateTime.UtcNow + Limit;
        while (!condition())
        {
            Assert.True(condition: DateTime.UtcNow < deadline, userMessage: "It didn't happen in time.");
            await Task.Delay(millisecondsDelay: 10, cancellationToken: TestContext.Current.CancellationToken);
        }
    }
}
