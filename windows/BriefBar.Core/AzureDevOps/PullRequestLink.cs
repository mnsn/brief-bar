using System.Text.RegularExpressions;

namespace BriefBar.Core.AzureDevOps;

/// A link to an Azure DevOps pull request, as you watch one, or as someone sends one in a message. The Mac's
/// `PullRequestLink`.
public sealed partial record PullRequestLink(string Organization, string Project, string Repository, int Number)
{
    public PRKey Key => new(Organization: Organization, Number: Number);

    public Uri Url => ADOEndpoint.PullRequestPage(organization: Organization, project: Project, repository: Repository, id: Number);

    /// Every pull request linked in `text`, once each, in order: `dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}`
    /// and the older `{org}.visualstudio.com[/DefaultCollection]/{project}/_git/{repo}/pullrequest/{id}`, with or without
    /// the scheme, a query or a fragment.
    public static IReadOnlyList<PullRequestLink> Find(string text)
    {
        ArgumentNullException.ThrowIfNull(argument: text);
        var links = new List<PullRequestLink>();
        if (!text.Contains(value: "pullrequest", comparisonType: StringComparison.OrdinalIgnoreCase))
        {
            return links;
        }
        foreach (Match match in Pattern().Matches(input: text))
        {
            var organization = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
            if (organization.Length == 0
                || !int.TryParse(s: match.Groups[5].Value, provider: System.Globalization.CultureInfo.InvariantCulture, result: out var number) || number <= 0)
            {
                continue;
            }
            var link = new PullRequestLink(
                Organization: organization,
                Project: Unescaped(text: match.Groups[3].Value),
                Repository: Unescaped(text: match.Groups[4].Value),
                Number: number);
            if (!links.Exists(match: found => found.Key == link.Key))
            {
                links.Add(item: link);
            }
        }
        return links;
    }

    [GeneratedRegex(
        pattern: """(?:https?://)?(?:dev\.azure\.com/([A-Za-z0-9][A-Za-z0-9-]*)|([A-Za-z0-9][A-Za-z0-9-]*)\.visualstudio\.com(?:/DefaultCollection)?)/([^\s/?#<>"'\]\[()]+)/_git/([^\s/?#<>"'\]\[()]+)/pullrequest/([0-9]{1,9})(?![0-9])""",
        options: RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Pattern();

    /// A name as a link carries it, with its percent-encoding taken off, or as it is when that isn't valid.
    static string Unescaped(string text)
    {
        try
        {
            return Uri.UnescapeDataString(stringToUnescape: text);
        }
        catch (UriFormatException)
        {
            return text;
        }
    }
}
