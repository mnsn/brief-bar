namespace BriefBar.Core.AzureDevOps;

/// Someone on a pull request, or a service such as a build service or a bot. Their ID is lowercased, so that IDs from
/// different endpoints compare equal.
public sealed record Person
{
    public Person(string id, string name, bool isBot = false)
    {
        ArgumentNullException.ThrowIfNull(argument: id);
        ArgumentNullException.ThrowIfNull(argument: name);
        Id = id.ToLowerInvariant();
        Name = name;
        IsBot = isBot;
    }

    public string Id { get; }

    public string Name { get; }

    /// A service identity, such as a build service or a bot, rather than a person.
    public bool IsBot { get; }

    /// "Sam" from "Sam Rivera", or from "Rivera, Sam", which puts the first name last.
    public string FirstName
    {
        get
        {
            var trimmed = Name.Trim();
            var comma = trimmed.IndexOf(value: ',', comparisonType: StringComparison.Ordinal);
            if (comma >= 0)
            {
                var rest = trimmed[(comma + 1)..].Trim();
                var first = rest.Split(separator: ' ', options: StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
                if (first is not null)
                {
                    return first;
                }
            }
            return trimmed.Split(separator: ' ', options: StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? trimmed;
        }
    }

    /// Someone, as Azure DevOps names them: "Someone" without a name.
    public static Person From(ADOIdentity identity)
    {
        ArgumentNullException.ThrowIfNull(argument: identity);
        return new Person(id: identity.Id, name: identity.DisplayName ?? "Someone", isBot: IsService(identity: identity));
    }

    /// People sign in with an email-style name; build services and bots don't have one.
    internal static bool IsService(ADOIdentity identity)
    {
        if (identity.IsContainer == true)
        {
            return true;
        }
        if (identity.UniqueName is { Length: > 0 } unique && !unique.Contains(value: '@', comparisonType: StringComparison.Ordinal))
        {
            return true;
        }
        var name = (identity.DisplayName ?? string.Empty).ToLowerInvariant();
        return name.EndsWith(value: " bot", comparisonType: StringComparison.Ordinal)
            || name.EndsWith(value: "[bot]", comparisonType: StringComparison.Ordinal)
            || name.Contains(value: "build service", comparisonType: StringComparison.Ordinal);
    }
}
