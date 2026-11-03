import Foundation

extension DemoData {
    /// What the demo says a Copilot session answers when you ask it about a thread with Explain: made up, as the rest of the
    /// demo's data is, never asked of Copilot.
    public static func explanation(ofThread thread: Int, pullRequest number: Int) -> String {
        switch (number, thread) {
        case (4102, 11):
            return """
                Sam wants a ceiling on how long one retry waits. The backoff starts at 200 ms and doubles with each \
                attempt, with nothing to stop it, so with `MaxAttempts` at 5 the last wait is 3.2 s, and if someone raises \
                the attempts, it grows past the 60 seconds after which the load balancer gives up on checkout anyway.

                The code he's on is `delay *= 2;` in `SendAsync`: it's the only place the delay grows.

                Ways to address it:

                - **Cap it where it doubles:** `delay = TimeSpan.FromTicks(Math.Min(delay.Ticks * 2, MaxDelay.Ticks));`, \
                with `MaxDelay` at 30 seconds. The smallest change.
                - **Make the cap configurable:** a `MaxDelay` on `RetryOptions`, next to `MaxAttempts`, as Priya suggests, \
                defaulting to 30 seconds.
                - **Cap the total instead:** stop retrying once the waits add up to 30 seconds, whatever the attempts. \
                Closer to what the load balancer cares about, but a bigger change.
                """
        case (4102, 18):
            return """
                Priya suggests putting the cap Sam asked for on `RetryOptions`, so it's configured with the attempts, \
                in `Payments:Retry`, rather than a constant in the client. Her suggestion adds `MaxDelay` there, at \
                30 seconds by default. Applying it as it's written also means reading it in `SendAsync` where the delay \
                doubles.
                """
        default:
            return """
                The reviewer is asking for a change to the lines this thread is on. From this session's work on the pull \
                request, the change they want is small and local: read their comment as a request rather than a \
                question, make it where they point, and say so in the thread.
                """
        }
    }
}
