using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// How one branch policy, such as a build, a status check or a reviewer rule, stands on a pull request. Its free-form
/// settings and context take a value of an unexpected type as missing.
public sealed record ADOPolicyEvaluation(string? Status, ADOPolicyConfiguration Configuration, ADOPolicyContext? Context = null, DateTimeOffset? CompletedDate = null)
{
    internal static ADOPolicyEvaluation? Read(JsonElement element) =>
        ADOJson.Node(element: element, name: "configuration") is { } node && ADOPolicyConfiguration.Read(element: node) is { } configuration
            ? new ADOPolicyEvaluation(
                Status: ADOJson.Text(element: element, name: "status"),
                Configuration: configuration,
                Context: ADOJson.Node(element: element, name: "context") is { } context ? ADOPolicyContext.Read(element: context) : null,
                CompletedDate: ADOJson.Date(element: element, name: "completedDate"))
            : null;
}
