using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A policy's configuration: whether it's on and blocking, its type's name, such as "Build", and its settings.
public sealed record ADOPolicyConfiguration(bool? IsEnabled, bool? IsBlocking, string TypeName, ADOPolicySettings? Settings = null)
{
    internal static ADOPolicyConfiguration? Read(JsonElement element) =>
        LenientJson.Text(element: LenientJson.Node(element: element, name: "type"), name: "displayName") is { } typeName
            ? new ADOPolicyConfiguration(
                IsEnabled: LenientJson.Flag(element: element, name: "isEnabled"),
                IsBlocking: LenientJson.Flag(element: element, name: "isBlocking"),
                TypeName: typeName,
                Settings: LenientJson.Node(element: element, name: "settings") is { } settings ? ADOPolicySettings.Read(element: settings) : null)
            : null;
}
