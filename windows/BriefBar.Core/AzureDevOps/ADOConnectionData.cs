using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// `_apis/connectionData`: who you are in an organization.
public sealed record ADOConnectionData(ADOAuthenticatedUser AuthenticatedUser)
{
    internal static ADOConnectionData? Read(JsonElement element) =>
        LenientJson.Node(element: element, name: "authenticatedUser") is { } user && LenientJson.Text(element: user, name: "id") is { } id
            ? new ADOConnectionData(AuthenticatedUser: new ADOAuthenticatedUser(Id: id, ProviderDisplayName: LenientJson.Text(element: user, name: "providerDisplayName")))
            : null;
}
