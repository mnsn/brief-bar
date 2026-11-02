using System.Text.Json;

namespace BriefBar.Core.GitHub;

/// One of the errors a GraphQL answer can carry, alongside what could be read or instead of it: its `Type`, such as
/// `RATE_LIMITED`, `FORBIDDEN` or `NOT_FOUND`, when GitHub says, and its message. The Mac's `GraphQLError`.
public sealed record GraphQLError(string Message, string? Type = null)
{
    /// The error in `element`, or null when it has no message, which the Mac can't decode either.
    internal static GraphQLError? Read(JsonElement element) =>
        LenientJson.Text(element: element, name: "message") is { } message
            ? new GraphQLError(Message: message, Type: LenientJson.Text(element: element, name: "type"))
            : null;
}
