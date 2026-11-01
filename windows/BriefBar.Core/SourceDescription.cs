namespace BriefBar.Core;

/// What a source says before you turn it on: what BriefBar reads for it and what it keeps, where it connects, and what
/// it needs. `Version` goes up whenever the source starts reading more than it says here, so that one you turned on
/// waits until you've seen the new description (`SourceChoices`).
public sealed record SourceDescription(int Version, string Summary, string Reads, string Network, string Needs);
