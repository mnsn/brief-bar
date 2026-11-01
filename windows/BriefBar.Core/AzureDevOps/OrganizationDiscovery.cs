namespace BriefBar.Core.AzureDevOps;

/// Finds the organizations to watch. The Mac's `OrganizationDiscovery`.
public static class OrganizationDiscovery
{
    /// Names in a list, in the order people read them, ignoring case.
    public static StringComparer NameOrder { get; } = StringComparer.InvariantCultureIgnoreCase;

    /// Every organization you're a member of, by name.
    public static async Task<IReadOnlyList<string>> MembershipsAsync(ADOClient client, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(argument: client);
        var profile = await client.GetAsync(url: ADOEndpoint.Profile, read: ADOProfile.Read, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        var accounts = await client.ListAsync(url: ADOEndpoint.Accounts(memberId: profile.PublicAlias ?? profile.Id), read: ADOAccount.Read, cancellationToken: cancellationToken)
            .ConfigureAwait(continueOnCapturedContext: false);
        return accounts.Value.Select(selector: account => account.AccountName).Order(comparer: NameOrder).ToList();
    }

    /// Your organizations, and those with your pull requests. Throws when it couldn't tell, as while offline, rather than
    /// finding none, and when Azure DevOps asked to slow down, rather than finding only some, so that it's tried again.
    public static async Task<OrganizationsFound> DiscoverAsync(ADOClient client, CancellationToken cancellationToken)
    {
        var all = await MembershipsAsync(client: client, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        var probe = await ProbeAsync(organizations: all, client: client, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        var failures = probe.Failures.OrderBy(keySelector: pair => pair.Key, comparer: StringComparer.Ordinal).Select(selector: pair => pair.Value).ToList();
        if (failures.Find(match: error => error.Kind == ADOErrorKind.Throttled) is { } slowedDown)
        {
            throw new ADOException(error: slowedDown);
        }
        if (probe.WithPullRequests.Count == 0 && failures.Count > 0)
        {
            throw new ADOException(error: failures[0]);
        }
        return new OrganizationsFound(All: all, WithPullRequests: probe.WithPullRequests);
    }

    /// Looks for your active pull requests in each organization, `concurrency` at a time.
    public static async Task<OrganizationProbe> ProbeAsync(IReadOnlyList<string> organizations, ADOClient client, CancellationToken cancellationToken, int concurrency = 6)
    {
        ArgumentNullException.ThrowIfNull(argument: organizations);
        var found = new HashSet<string>(comparer: StringComparer.Ordinal);
        var failures = new Dictionary<string, ADOError>(comparer: StringComparer.Ordinal);
        using var slots = new SemaphoreSlim(initialCount: Math.Max(val1: 1, val2: concurrency));
        async Task Check(string organization)
        {
            await slots.WaitAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            try
            {
                var has = await HasPullRequestsAsync(organization: organization, client: client, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                lock (found)
                {
                    if (has)
                    {
                        found.Add(item: organization);
                    }
                }
            }
            catch (ADOException error)
            {
                lock (found)
                {
                    failures[organization] = error.Error;
                }
            }
            finally
            {
                slots.Release();
            }
        }
        await Task.WhenAll(tasks: organizations.Select(selector: Check)).ConfigureAwait(continueOnCapturedContext: false);
        return new OrganizationProbe(WithPullRequests: organizations.Where(predicate: found.Contains).ToList(), Failures: failures);
    }

    /// The union of two lists of organization names, which Azure DevOps compares ignoring case, spelled as `preferred`
    /// spells them, in order.
    public static IReadOnlyList<string> Merged(IEnumerable<string> names, IEnumerable<string> preferred)
    {
        ArgumentNullException.ThrowIfNull(argument: names);
        ArgumentNullException.ThrowIfNull(argument: preferred);
        var merged = new List<string>();
        foreach (var name in preferred.Concat(second: names))
        {
            if (!merged.Exists(match: existing => string.Equals(a: existing, b: name, comparisonType: StringComparison.OrdinalIgnoreCase)))
            {
                merged.Add(item: name);
            }
        }
        return merged.Order(comparer: NameOrder).ToList();
    }

    /// Organization names are letters, digits and hyphens, at most 50, not starting with a hyphen.
    public static bool IsValidName(string name)
    {
        ArgumentNullException.ThrowIfNull(argument: name);
        return name.Length is > 0 and <= 50 && name[0] != '-' && name.All(predicate: character => char.IsAsciiLetterOrDigit(c: character) || character == '-');
    }

    /// The organization in what you typed or pasted: `contoso`, `dev.azure.com/contoso/…`, `https://contoso.visualstudio.com/…`.
    /// Null when there's none.
    public static string? NameFrom(string input)
    {
        ArgumentNullException.ThrowIfNull(argument: input);
        var text = input.Trim();
        foreach (var scheme in new[] { "https://", "http://" })
        {
            if (text.StartsWith(value: scheme, comparisonType: StringComparison.OrdinalIgnoreCase))
            {
                text = text[scheme.Length..];
            }
        }
        var parts = text.Split(separator: '/', options: StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0)
        {
            return null;
        }
        var first = parts[0];
        var host = first.ToLowerInvariant();
        string? candidate;
        if (host == "dev.azure.com")
        {
            candidate = parts.Length > 1 ? parts[1] : null;
        }
        else if (host.EndsWith(value: ".visualstudio.com", comparisonType: StringComparison.Ordinal))
        {
            candidate = first[..^".visualstudio.com".Length];
        }
        else
        {
            candidate = parts.Length == 1 ? first : null;
        }
        return candidate is not null && IsValidName(name: candidate) ? candidate : null;
    }

    /// Whether you have an active pull request in `organization`, as its author or a reviewer. One you can't read, in
    /// another tenant or without access, has nothing of yours to show; anything else throws.
    internal static async Task<bool> HasPullRequestsAsync(string organization, ADOClient client, CancellationToken cancellationToken)
    {
        try
        {
            var me = (await client.GetAsync(url: ADOEndpoint.ConnectionData(organization: organization), read: ADOConnectionData.Read, cancellationToken: cancellationToken)
                .ConfigureAwait(continueOnCapturedContext: false)).AuthenticatedUser.Id;
            foreach (var url in new[]
            {
                ADOEndpoint.PullRequests(organization: organization, status: "active", creatorId: me, top: 1),
                ADOEndpoint.PullRequests(organization: organization, status: "active", reviewerId: me, top: 1),
            })
            {
                var list = await client.ListAsync(url: url, read: ADOPullRequest.Read, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                if (list.Value.Count > 0)
                {
                    return true;
                }
            }
            return false;
        }
        catch (ADOException error) when (error.Error.Kind is ADOErrorKind.Unauthorized or ADOErrorKind.Forbidden or ADOErrorKind.NotFound)
        {
            // Another tenant, or no access: nothing of yours to show there.
            return false;
        }
    }
}
