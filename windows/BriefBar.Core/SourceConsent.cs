namespace BriefBar.Core;

/// That you turned a source on, having seen what it reads: the version of its description you saw, and when.
public sealed record SourceConsent(int Version, DateTimeOffset Date);
