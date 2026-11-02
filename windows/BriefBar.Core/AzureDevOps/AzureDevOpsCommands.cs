namespace BriefBar.Core.AzureDevOps;

/// What the pull requests' panel can ask the Azure DevOps section to do, by `PanelCommand.Key`.
public static class AzureDevOpsCommands
{
    /// A row: opens its pull request in Azure DevOps, at the comment that needs you, and sees it.
    public const string Open = "open";

    /// A row in Needs you: takes it off, up to what the panel showed.
    public const string RemoveFromNeedsYou = "removeFromNeedsYou";

    /// A row you watch: stops watching it.
    public const string StopWatching = "stopWatching";

    /// Needs you: sees everything there, keeping the comments that wait on you.
    public const string MarkAsSeen = "markAsSeen";

    /// Done: sees everything there, which empties it.
    public const string Clear = "clear";

    /// The section: your organization's pull requests in Azure DevOps.
    public const string OpenAzureDevOps = "openAzureDevOps";

    /// The section: reads again now.
    public const string Refresh = "refresh";

    /// The section: signs in to the Azure CLI, in a console window.
    public const string SignIn = "signIn";

    /// The section: the page that says how to install the Azure CLI.
    public const string InstallCli = "installCli";

    /// Settings: looks for your organizations again, and watches those where you have pull requests.
    public const string FindOrganizations = "findOrganizations";

    /// What every command that sorts the list starts with, before its order's name.
    const string SortPrefix = "sort.";

    /// What every command that signs in to a directory starts with, before the directory's ID.
    const string SignInPrefix = SignIn + ".";

    /// The section's list: lists them in `order`, and keeps it, as `SortedBy` reads it back.
    public static string Sort(PROrder order) => SortPrefix + order.RawValue();

    /// The order `command` sorts the list in, as `Sort` names it; null for any other command.
    public static PROrder? SortedBy(string command)
    {
        ArgumentNullException.ThrowIfNull(argument: command);
        return command.StartsWith(value: SortPrefix, comparisonType: StringComparison.Ordinal)
            ? PROrders.FromRawValue(rawValue: command[SortPrefix.Length..])
            : null;
    }

    /// The section, or Settings: signs in to the Azure CLI in the directory `tenant`, an organization's or your sign-in's own,
    /// with `az login --tenant`, as `SignInTenant` reads it back.
    public static string SignInTo(string tenant)
    {
        ArgumentNullException.ThrowIfNull(argument: tenant);
        return SignInPrefix + tenant;
    }

    /// The directory `command` signs in to, as `SignInTo` names it: only a directory's ID, a GUID; null for any other
    /// command.
    public static string? SignInTenant(string command)
    {
        ArgumentNullException.ThrowIfNull(argument: command);
        return command.StartsWith(value: SignInPrefix, comparisonType: StringComparison.Ordinal) ? TenantId.From(text: command[SignInPrefix.Length..]) : null;
    }
}
