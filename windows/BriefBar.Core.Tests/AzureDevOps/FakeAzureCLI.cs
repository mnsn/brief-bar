using System.Text.Json.Nodes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// A made-up Azure CLI, signed in as an account from one directory, to some directories, one of them its default, as
/// `az login --tenant` leaves it. `az account get-access-token` gets a made-up token for the directory it asks for with
/// `--tenant`, or for the default: the account's own there, or a guest's elsewhere, as its directory names it; or fails
/// as the Azure CLI does when it isn't signed in there. As the Swift tests' `FakeAzureCLI`.
internal sealed class FakeAzureCLI : IProcessRunner
{
    readonly Lock gate = new();
    readonly HeldDirectory? held;
    readonly List<IReadOnlyList<string>> runs = [];
    string defaultTenant;
    HashSet<string> signedIn;
    /// The directory the signed-in account is from: elsewhere, it's a guest.
    string accountTenant;
    /// Who's signed in, as the tokens' object IDs name them.
    string objectId = "robin";

    public FakeAzureCLI(string defaultTenant, IEnumerable<string> signedIn, string? accountFrom = null, HeldDirectory? held = null)
    {
        this.defaultTenant = defaultTenant;
        this.signedIn = [.. signedIn];
        accountTenant = accountFrom ?? defaultTenant;
        this.held = held;
    }

    /// Each run's arguments, in order.
    public IReadOnlyList<IReadOnlyList<string>> Runs
    {
        get
        {
            lock (gate)
            {
                return [.. runs];
            }
        }
    }

    /// The directory each run asked for with `--tenant`: null for none, the default.
    public IReadOnlyList<string?> Asked => Runs.Select(selector: TenantOf).ToList();

    /// `az login --tenant`: signed in there too, which becomes the default.
    public void SignInTo(string tenant)
    {
        lock (gate)
        {
            signedIn.Add(item: tenant);
            defaultTenant = tenant;
        }
    }

    /// A directory that wants you to sign in again, such as for multi-factor authentication.
    public void Expire(string tenant)
    {
        lock (gate)
        {
            signedIn.Remove(item: tenant);
        }
    }

    /// Someone else signs in, with an account from `tenant`, to `directories`: `who` tells two from one directory apart.
    public void SwitchAccount(string tenant, IEnumerable<string> directories, string who = "robin")
    {
        lock (gate)
        {
            accountTenant = tenant;
            signedIn = [.. directories];
            defaultTenant = tenant;
            objectId = who;
        }
    }

    public async Task<ProcessResult> RunAsync(
        string program, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string?> environment, TimeSpan timeout, CancellationToken cancellationToken)
    {
        string tenant;
        bool isSignedIn;
        string from;
        string who;
        lock (gate)
        {
            runs.Add(item: [.. arguments]);
            tenant = TenantOf(arguments: arguments) ?? defaultTenant;
            isSignedIn = signedIn.Contains(item: tenant);
            from = accountTenant;
            who = objectId;
        }
        if (held is not null)
        {
            await held.HoldAsync(asked: tenant);
        }
        if (!isSignedIn)
        {
            return new ProcessResult(ExitCode: 1, Output: string.Empty, Error: "ERROR: AADSTS50076: Sign in with multi-factor authentication.\n");
        }
        var token = tenant == from ? MadeUpTokens.For(tenant: tenant, objectId: who) : MadeUpTokens.For(tenant: tenant, objectId: who + "-guest", guestFrom: from);
        return new ProcessResult(ExitCode: 0, Output: new JsonObject { ["accessToken"] = token, ["expires_on"] = 4_102_444_800 }.ToJsonString(), Error: string.Empty);
    }

    public void StartInConsole(
        string program, IReadOnlyList<string> arguments, string? workingDirectory, IReadOnlyDictionary<string, string?> environment, bool keepOpen) =>
        throw new InvalidOperationException(message: "Nothing starts in a console window here.");

    static string? TenantOf(IReadOnlyList<string> arguments)
    {
        for (var index = 0; index < arguments.Count - 1; index++)
        {
            if (arguments[index] == "--tenant")
            {
                return arguments[index + 1];
            }
        }
        return null;
    }
}
