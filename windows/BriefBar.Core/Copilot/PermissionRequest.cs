namespace BriefBar.Core.Copilot;

/// A permission prompt the agent waits on, from `permission.requested`: what kind, and what it's for in a few words.
public sealed record PermissionRequest
{
    public required string RequestId { get; init; }

    public string? Kind { get; init; }

    public string? Detail { get; init; }
}
