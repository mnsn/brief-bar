namespace BriefBar.Core.AzureDevOps;

/// What you've seen, for each account you've signed in to the Azure CLI with: two accounts can see the same pull request,
/// and what one has seen of it says nothing about what the other has. `Current` is the account signed in now, or last;
/// `Others`, the other accounts' states, by account. The Mac's `SeenBook`.
public sealed record SeenBook(SeenState Current, IReadOnlyDictionary<string, SeenState> Others)
{
    /// The state for `account`, without switching to it.
    public SeenState State(string? account, DateTimeOffset now)
    {
        if (account is null || Current.Account is not { } current || current == account)
        {
            return Current;
        }
        return Others.TryGetValue(key: account, value: out var other) ? other : SeenState.FirstRun(now: now, account: account);
    }

    /// Switches to `account`'s state, keeping the current one for when its account signs in again. A state from before
    /// accounts were told apart becomes this account's. `Switched` says whether it was another account's.
    public (SeenBook Book, bool Switched) SigningIn(string account, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: account);
        if (Current.Account == account)
        {
            return (this, false);
        }
        if (Current.Account is not { } previous)
        {
            return (this with { Current = Current with { Account = account } }, false);
        }
        var others = new Dictionary<string, SeenState>(collection: Others, comparer: StringComparer.Ordinal) { [previous] = Current };
        var current = others.Remove(key: account, value: out var saved) ? saved : SeenState.FirstRun(now: now, account: account);
        return (new SeenBook(Current: current, Others: others), true);
    }
}
