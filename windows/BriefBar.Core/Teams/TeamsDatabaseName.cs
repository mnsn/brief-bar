using System.Text.RegularExpressions;

namespace BriefBar.Core.Teams;

/// The name of one of Teams' IndexedDB databases: `Teams:<manager>:react-web-client:<tenant>:<user>:<locale>`, such as
/// `Teams:conversation-manager:…`. `Account` is what follows the manager, the same in each of an account's databases;
/// `UserId` is that account's user ID, a GUID, as its messages name their sender.
internal readonly partial record struct TeamsDatabaseName(string Manager, string Account, string UserId)
{
    public const string Conversations = "conversation-manager";
    public const string ReplyChains = "replychain-manager";

    /// The parts of `name`, or null for one that isn't a Teams database of an account.
    public static TeamsDatabaseName? Parse(string name)
    {
        ArgumentNullException.ThrowIfNull(argument: name);
        const string start = "Teams:";
        if (!name.StartsWith(value: start, comparisonType: StringComparison.Ordinal))
        {
            return null;
        }
        var rest = name[start.Length..];
        var colon = rest.IndexOf(value: ':', comparisonType: StringComparison.Ordinal);
        if (colon <= 0)
        {
            return null;
        }
        var account = rest[(colon + 1)..];
        var user = Guid().Matches(input: account).LastOrDefault()?.Value;
        return user is null ? null : new TeamsDatabaseName(Manager: rest[..colon], Account: account, UserId: user.ToLowerInvariant());
    }

    [GeneratedRegex(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", options: RegexOptions.CultureInvariant)]
    private static partial Regex Guid();
}
