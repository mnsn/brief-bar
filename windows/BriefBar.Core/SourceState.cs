namespace BriefBar.Core;

public enum SourceState
{
    Off,
    On,

    /// You turned it on, but it reads more now than what you saw then, so it waits until you've seen what it reads now.
    NeedsReview,
}
