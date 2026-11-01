using System.Text.Json;

namespace BriefBar.Core.GitHub;

/// A reviewer's latest review that approves or requests changes, as the query reads it: its state, such as `APPROVED`,
/// and who wrote it, null for a deleted account. The Mac's `APIPullRequest.Review`.
public sealed record APIPullRequestReview(string State, string? Author)
{
    /// The review in `element`, or null without a state.
    internal static APIPullRequestReview? Read(JsonElement element) =>
        LenientJson.Text(element: element, name: "state") is { } state
            ? new APIPullRequestReview(State: state, Author: LenientJson.Text(element: LenientJson.Node(element: element, name: "author"), name: "login"))
            : null;
}
