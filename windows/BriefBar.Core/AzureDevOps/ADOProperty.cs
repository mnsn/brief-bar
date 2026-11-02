using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A thread property, `{"$type": "System.String", "$value": "VoteUpdate"}`, its value as text whatever its JSON type, or
/// null for one that isn't an object or has no value of a simple type.
public sealed record ADOProperty(string? Value)
{
    internal static ADOProperty Read(JsonElement element) => new(Value: LenientJson.AnyText(element: LenientJson.Member(element: element, name: "$value")));
}
