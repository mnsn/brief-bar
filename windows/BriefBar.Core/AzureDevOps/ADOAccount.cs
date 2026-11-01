using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// One organization you're a member of, from `app.vssps.visualstudio.com/_apis/accounts`.
public sealed record ADOAccount(string AccountName)
{
    internal static ADOAccount? Read(JsonElement element) =>
        ADOJson.Text(element: element, name: "accountName") is { } name ? new ADOAccount(AccountName: name) : null;
}
