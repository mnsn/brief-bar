namespace BriefBar.Core.Copilot;

/// A permission prompt the main agent waits on.
[System.Diagnostics.CodeAnalysis.SuppressMessage(
    category: "Naming", checkId: "CA1711", Justification = "The Mac's name: a prompt the agent waits on, not a .NET permission.")]
public sealed record PendingPermission
{
    public required string RequestId { get; init; }

    public string? Kind { get; init; }

    public string? Detail { get; init; }

    public DateTimeOffset? RequestedAt { get; init; }
}
