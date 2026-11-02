using System.Net;
using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Organizations in another directory, a Microsoft Entra tenant, than your sign-in's: Azure DevOps reads each one only with
/// a token from its own directory, and names it when it rejects one from another. With made-up directories, tokens and
/// organizations only. The Swift tests' `DirectoryTests`, for what Windows has: pull requests, without the Sprint,
/// Pipelines, work items, the command line or agents.
public sealed class DirectoryTests
{
    const string MultiFactor = "AADSTS50076: Sign in with multi-factor authentication.";

    static readonly DateTimeOffset now = TestTimes.T(seconds: 0);

    static readonly AuthError someoneElse = AuthError.Failed(message: "Someone else signed in to the Azure CLI.");

    static CancellationToken Cancellation => TestContext.Current.CancellationToken;

    // Tokens

    [Fact]
    public void ReadsWhichDirectoryATokenIsFor()
    {
        var token = MadeUpTokens.For(tenant: Tenants.Other.ToUpperInvariant());
        Assert.Equal(expected: Tenants.Other, actual: AccessToken.TenantInJwt(token: token));
        Assert.Null(@object: AccessToken.TenantInJwt(token: "opaque"));
        // A member's account is in the token's directory; a guest's, in the one its `idp` names.
        Assert.Equal(expected: Tenants.Other, actual: AccessToken.AccountTenantInJwt(token: token));
        var guest = MadeUpTokens.For(tenant: Tenants.Other, objectId: "robin-guest", guestFrom: Tenants.Home.ToUpperInvariant());
        Assert.Equal(expected: Tenants.Home, actual: AccessToken.AccountTenantInJwt(token: guest));
        // A personal Microsoft account's names its identity provider.
        Assert.Equal(expected: "live.com", actual: AccessToken.AccountTenantInJwt(token: MadeUpTokens.For(tenant: Tenants.Other, guestFrom: "live.com")));
        // What the token says counts, over what the Azure CLI says it asked for.
        var parsed = AzureCLITokenProvider.ParseToken(
            output: new JsonObject { ["accessToken"] = guest, ["tenant"] = Tenants.Third, ["expires_on"] = 4_102_444_800 }.ToJsonString(), now: now);
        Assert.Equal(expected: Tenants.Other, actual: parsed.Tenant);
        Assert.Equal(expected: Tenants.Home, actual: parsed.AccountTenant);
        Assert.Equal(expected: Tenants.Other + "/robin-guest", actual: parsed.Account);
        var opaque = AzureCLITokenProvider.ParseToken(output: new JsonObject { ["accessToken"] = "abc", ["tenant"] = Tenants.Home.ToUpperInvariant() }.ToJsonString(), now: now);
        Assert.Equal(expected: Tenants.Home, actual: opaque.Tenant);
        Assert.Null(@object: opaque.AccountTenant);
        Assert.Equal(expected: Tenants.Home, actual: AccessToken.TenantOfAccount(account: Tenants.Home + "/robin"));
        Assert.Null(@object: AccessToken.TenantOfAccount(account: "/robin"));
        // Only a GUID is a directory's ID, since one goes to `az --tenant`, which `cmd.exe` runs: not the empty one either.
        Assert.Null(@object: AccessToken.TenantInJwt(token: MadeUpTokens.For(tenant: "contoso & calc")));
        Assert.Null(@object: AccessToken.TenantInJwt(token: MadeUpTokens.For(tenant: Guid.Empty.ToString())));
    }

    [Fact]
    public async Task AsksTheAzureCLIForAnotherDirectorysTokenWithIt()
    {
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home, Tenants.Other]);
        var provider = Provider(cli: cli);
        Assert.Equal(expected: Tenants.Other, actual: (await provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation)).Tenant);
        // Kept for that directory, however its ID is written, and apart from yours.
        Assert.Equal(expected: Tenants.Other, actual: (await provider.TokenAsync(tenant: Tenants.Other.ToUpperInvariant(), cancellationToken: Cancellation)).Tenant);
        Assert.Equal(expected: Tenants.Home, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        Assert.Equal(expected: [Tenants.Other, null], actual: cli.Asked);
        // Forgetting one directory's token keeps the others'.
        provider.Invalidate(tenant: Tenants.Other);
        await provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation);
        await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        Assert.Equal(expected: [Tenants.Other, null, Tenants.Other], actual: cli.Asked);
        // Fixed words only, which a batch file can take: the directory's ID after `--tenant`.
        Assert.Equal(expected: [.. AzureCLITokenProvider.Arguments, "--tenant", Tenants.Other], actual: cli.Runs[0]);
        Assert.Equal(expected: AzureCLITokenProvider.Arguments, actual: cli.Runs[1]);
    }

    /// Nothing but a directory's ID goes to `az --tenant`: asked for anything else, it runs nothing, and a directory kept from
    /// before that isn't one isn't asked for.
    [Fact]
    public async Task OnlyADirectorysIDGoesToTheAzureCLI()
    {
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home]);
        var provider = Provider(cli: cli);
        await Assert.ThrowsAsync<ArgumentException>(testCode: () => provider.TokenAsync(tenant: "contoso & calc", cancellationToken: Cancellation));
        Assert.Empty(collection: cli.Runs);

        var kept = Provider(cli: cli, homeTenant: "contoso & calc", homeAccountTenant: " ");
        Assert.Equal(expected: Tenants.Home, actual: (await kept.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        Assert.Equal(expected: [null], actual: cli.Asked);
    }

    [Fact]
    public async Task SigningInToAnotherDirectoryDoesntChangeWhoBriefBarReadsAs()
    {
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home]);
        var provider = Provider(cli: cli);
        // Yours, in the Azure CLI's default directory, which BriefBar keeps as yours.
        Assert.Equal(expected: Tenants.Home, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        // Not signed in to fabrikam's directory.
        var error = await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation));
        Assert.Equal(expected: AuthError.SignedOut(message: MultiFactor), actual: error.Error);
        // `az login --tenant` there makes it the Azure CLI's default; yours is still asked for in your directory.
        cli.SignInTo(tenant: Tenants.Other);
        Assert.Equal(expected: Tenants.Other, actual: (await provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation)).Tenant);
        provider.Invalidate(tenant: null);
        var yours = await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        Assert.Equal(expected: Tenants.Home, actual: yours.Tenant);
        Assert.Equal(expected: Tenants.Home + "/robin", actual: yours.Account);
        Assert.Equal(expected: [null, Tenants.Other, Tenants.Other, Tenants.Home], actual: cli.Asked);
    }

    [Fact]
    public async Task YourDirectoryWantingYouToSignInAgainIsntSomeoneElses()
    {
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home]);
        var provider = Provider(cli: cli);
        Assert.Equal(expected: Tenants.Home, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        // You sign in to fabrikam's directory, which becomes the Azure CLI's default; later, yours wants you to sign in
        // again, while fabrikam's still gives your guest account tokens.
        cli.SignInTo(tenant: Tenants.Other);
        cli.Expire(tenant: Tenants.Home);
        provider.Invalidate(tenant: null);
        // Signing in again there is what fixes it.
        var error = await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(tenant: null, cancellationToken: Cancellation));
        Assert.Equal(expected: AuthError.SignedOut(message: MultiFactor, tenant: Tenants.Home), actual: error.Error);
        // Signed in to yours again, BriefBar reads as you there, not as your guest account in fabrikam's.
        cli.SignInTo(tenant: Tenants.Home);
        var yours = await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        Assert.Equal(expected: Tenants.Home, actual: yours.Tenant);
        Assert.Equal(expected: Tenants.Home + "/robin", actual: yours.Account);
        Assert.Equal(expected: [null, Tenants.Home, null, Tenants.Home], actual: cli.Asked);
    }

    [Fact]
    public async Task SomeoneElseSignedInItFollowsTheAzureCLIsDefault()
    {
        // BriefBar last read as you, in your directory; the Azure CLI is signed in as someone else now, from another.
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Other, signedIn: [Tenants.Other]);
        var provider = Provider(cli: cli, homeTenant: Tenants.Home.ToUpperInvariant());
        Assert.Equal(expected: Tenants.Other, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        Assert.Equal(expected: [Tenants.Home, null], actual: cli.Asked);
        // Their directory is the one tokens are asked for in from then on.
        provider.Invalidate(tenant: null);
        Assert.Equal(expected: Tenants.Other, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        Assert.Equal(expected: [Tenants.Home, null, Tenants.Other], actual: cli.Asked);
    }

    [Fact]
    public async Task YourGuestDirectoryWantingYouToSignInAgainIsntSomeoneElses()
    {
        // The Azure CLI's default was a directory your account is a guest in, from yours.
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Other, signedIn: [Tenants.Other], accountFrom: Tenants.Home);
        var provider = Provider(cli: cli);
        Assert.Equal(expected: Tenants.Other, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        // You sign in to a third one, a guest there too; then the first wants you to sign in again.
        cli.SignInTo(tenant: Tenants.Third);
        cli.Expire(tenant: Tenants.Other);
        provider.Invalidate(tenant: null);
        // There: a plain `az login` may sign in to another directory, without what this one asks for.
        var error = await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(tenant: null, cancellationToken: Cancellation));
        Assert.Equal(expected: AuthError.SignedOut(message: MultiFactor, tenant: Tenants.Other), actual: error.Error);
        Assert.Equal(expected: [null, Tenants.Other, null], actual: cli.Asked);
    }

    [Fact]
    public async Task AfterARestartYourGuestDirectoryWantingYouToSignInAgainIsntSomeoneElses()
    {
        // BriefBar last read as your guest account in fabrikam's directory, from yours, and kept where it's from. Since the
        // restart, the Azure CLI's default is a third directory you're a guest in too, and fabrikam's wants a sign-in.
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Third, signedIn: [Tenants.Third], accountFrom: Tenants.Home);
        var provider = Provider(cli: cli, homeTenant: Tenants.Other, homeAccountTenant: Tenants.Home.ToUpperInvariant());
        // It's still you: fabrikam's directory wants you to sign in again, there, rather than BriefBar reading as you there.
        var error = await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(tenant: null, cancellationToken: Cancellation));
        Assert.Equal(expected: AuthError.SignedOut(message: MultiFactor, tenant: Tenants.Other), actual: error.Error);
        // Signed in there again, yours comes from there, as before the restart, and your account is still from your directory.
        cli.SignInTo(tenant: Tenants.Other);
        var token = await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        Assert.Equal(expected: Tenants.Other, actual: token.Tenant);
        var account = Assert.IsType<string>(@object: token.Account);
        Assert.Equal(expected: Tenants.Home, actual: provider.AccountTenantOf(account: account));
        // Nothing is said of anyone else's.
        Assert.Null(@object: provider.AccountTenantOf(account: "someone-else"));
        Assert.Equal(expected: [Tenants.Other, null, Tenants.Other], actual: cli.Asked);
    }

    [Fact]
    public async Task APersonalAccountsDirectoryWantingYouToSignInAgainIsntSomeoneElses()
    {
        // A personal Microsoft account, a guest in each directory: its tokens name live.com, not a directory.
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home], accountFrom: "live.com");
        var provider = Provider(cli: cli);
        Assert.Equal(expected: "live.com", actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).AccountTenant);
        cli.SignInTo(tenant: Tenants.Other);
        cli.Expire(tenant: Tenants.Home);
        provider.Invalidate(tenant: null);
        var error = await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(tenant: null, cancellationToken: Cancellation));
        Assert.Equal(expected: AuthError.SignedOut(message: MultiFactor, tenant: Tenants.Home), actual: error.Error);
        Assert.Equal(expected: [null, Tenants.Home, null], actual: cli.Asked);
    }

    [Fact]
    public async Task SomeoneElsesSignInDropsTheLastAccountsTokens()
    {
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home, Tenants.Other]);
        var provider = Provider(cli: cli);
        await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        Assert.Equal(expected: Tenants.Home, actual: (await provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation)).AccountTenant);
        // Someone from the third directory signs in, a guest in fabrikam's too.
        cli.SwitchAccount(tenant: Tenants.Third, directories: [Tenants.Third, Tenants.Other]);
        provider.Invalidate(tenant: null);
        Assert.Equal(expected: Tenants.Third, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        // fabrikam's token was the last account's: it's asked for again, as theirs.
        Assert.Equal(expected: Tenants.Third, actual: (await provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation)).AccountTenant);
        Assert.Equal(expected: [null, Tenants.Other, Tenants.Home, null, Tenants.Other], actual: cli.Asked);
    }

    [Fact]
    public async Task AnotherDirectorysTokenForSomeoneElseIsntKept()
    {
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home, Tenants.Other]);
        var provider = Provider(cli: cli);
        await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        // Someone else signs in while yours is kept: a token from fabrikam's directory is theirs, and no caller gets it.
        cli.SwitchAccount(tenant: Tenants.Third, directories: [Tenants.Third, Tenants.Other]);
        var first = provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation);
        var second = provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation);
        foreach (var caller in new[] { first, second })
        {
            Assert.Equal(expected: someoneElse, actual: (await Assert.ThrowsAsync<AuthException>(testCode: () => caller)).Error);
        }
        // Nor is it kept, and yours is asked for again, which tells who's signed in now.
        Assert.Equal(expected: someoneElse, actual: (await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation))).Error);
        Assert.Equal(expected: Tenants.Third, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        Assert.Equal(expected: [Tenants.Home, null], actual: cli.Asked.TakeLast(count: 2));
    }

    [Fact]
    public async Task AnotherDirectorysTokenOnItsWayWhenSomeoneElseSignsInIsntKept()
    {
        var held = new HeldDirectory(tenant: Tenants.Other);
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home, Tenants.Other], held: held);
        var provider = Provider(cli: cli);
        var yours = await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        // A token from fabrikam's directory is on its way, for you, when someone else from your own directory signs in, as
        // the next token for yours tells: theirs from fabrikam's directory name the same directory as yours.
        var fabrikams = provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation);
        await Waiting.Until(condition: () => held.IsHolding);
        cli.SwitchAccount(tenant: Tenants.Home, directories: [Tenants.Home, Tenants.Other], who: "sam");
        provider.Invalidate(tenant: null);
        Assert.NotEqual(expected: yours.Account, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Account);
        held.Release();
        // It was yours: nobody waiting for it gets it, and it isn't kept for them.
        Assert.Equal(expected: someoneElse, actual: (await Assert.ThrowsAsync<AuthException>(testCode: () => fabrikams)).Error);
        Assert.Equal(expected: Tenants.Other + "/sam-guest", actual: (await provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation)).Account);
        Assert.Equal(expected: [null, Tenants.Other, Tenants.Home, Tenants.Other], actual: cli.Asked);
    }

    [Fact]
    public async Task SomeoneElseFoundThroughAnotherDirectoryDropsEveryTokenKept()
    {
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home, Tenants.Other]);
        var provider = Provider(cli: cli);
        await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        var fabrikams = await provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation);
        // Someone else signs in, from a third directory, a guest in fabrikam's too, and a token from their own directory is
        // the first to tell.
        cli.SwitchAccount(tenant: Tenants.Third, directories: [Tenants.Third, Tenants.Other], who: "sam");
        Assert.Equal(expected: someoneElse, actual: (await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(tenant: Tenants.Third, cancellationToken: Cancellation))).Error);
        // fabrikam's, kept for the last account, goes too: it isn't read as them meanwhile.
        Assert.Equal(expected: someoneElse, actual: (await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation))).Error);
        // Once theirs is read, fabrikam's is theirs.
        Assert.Equal(expected: Tenants.Third, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        var theirs = await provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation);
        Assert.Equal(expected: Tenants.Other + "/sam-guest", actual: theirs.Account);
        Assert.NotEqual(expected: fabrikams.Account, actual: theirs.Account);
        Assert.Equal(expected: [null, Tenants.Other, Tenants.Third, Tenants.Other, Tenants.Home, null, Tenants.Other], actual: cli.Asked);
    }

    [Fact]
    public async Task ATokenOnItsWayForTheLastAccountDoesntDropTheNextAccounts()
    {
        var held = new HeldDirectory(tenant: Tenants.Other);
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home, Tenants.Other], held: held);
        var provider = Provider(cli: cli);
        await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        // fabrikam's token, for you, is on its way when someone else signs in, from a third directory, and BriefBar has read
        // as them since, in their own directory too.
        var fabrikams = provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation);
        await Waiting.Until(condition: () => held.IsHolding);
        cli.SwitchAccount(tenant: Tenants.Third, directories: [Tenants.Third, Tenants.Other], who: "sam");
        provider.Invalidate(tenant: null);
        var theirHome = await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        Assert.Equal(expected: Tenants.Third, actual: theirHome.Tenant);
        var theirs = await provider.TokenAsync(tenant: Tenants.Third, cancellationToken: Cancellation);
        held.Release();
        // Yours, the last account's, isn't theirs: nobody gets it, and what's kept for them stays.
        Assert.Equal(expected: someoneElse, actual: (await Assert.ThrowsAsync<AuthException>(testCode: () => fabrikams)).Error);
        Assert.Equal(expected: theirHome, actual: await provider.TokenAsync(tenant: null, cancellationToken: Cancellation));
        Assert.Equal(expected: theirs, actual: await provider.TokenAsync(tenant: Tenants.Third, cancellationToken: Cancellation));
        Assert.Equal(expected: [null, Tenants.Other, Tenants.Home, null, Tenants.Third], actual: cli.Asked);
    }

    [Fact]
    public async Task YourTokenOnItsWayWhenSomeoneElseIsFoundIsntKept()
    {
        var held = new HeldDirectory(tenant: Tenants.Home, run: 2);
        var cli = new FakeAzureCLI(defaultTenant: Tenants.Home, signedIn: [Tenants.Home, Tenants.Other], held: held);
        var provider = Provider(cli: cli);
        await provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        // Yours is asked for again, and is on its way when someone else signs in, from a third directory, a guest in
        // fabrikam's, as a token from fabrikam's directory tells meanwhile.
        provider.Invalidate(tenant: null);
        var yours = provider.TokenAsync(tenant: null, cancellationToken: Cancellation);
        await Waiting.Until(condition: () => held.IsHolding);
        cli.SwitchAccount(tenant: Tenants.Third, directories: [Tenants.Third, Tenants.Other], who: "sam");
        Assert.Equal(expected: someoneElse, actual: (await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(tenant: Tenants.Other, cancellationToken: Cancellation))).Error);
        held.Release();
        // It was the last account's: nobody waiting for it gets it, nor is it kept, and the next one is theirs.
        Assert.Equal(expected: someoneElse, actual: (await Assert.ThrowsAsync<AuthException>(testCode: () => yours)).Error);
        Assert.Equal(expected: Tenants.Third, actual: (await provider.TokenAsync(tenant: null, cancellationToken: Cancellation)).Tenant);
        Assert.Equal(expected: [null, Tenants.Home, Tenants.Other, Tenants.Home, null], actual: cli.Asked);
    }

    /// What the Azure CLI says goes to the panel, and could reach the log: without IDs, email addresses or the names of
    /// directories it quotes or names, even names that hold quotes themselves, and none of it left by cutting it short.
    [Fact]
    public void WhatTheAzureCLISaysKeepsNoIDsOrNames()
    {
        var output = "WARNING: something\r\n"
            + "ERROR: AADSTS50020: User account 'robin@contoso.example' from identity provider 'live.com' does not exist in tenant 'Fabrikam Example' "
            + "and cannot access the application '" + AzureCLITokenProvider.AzureDevOpsResource + "'. Trace ID: 0d0d0d0d-4444-4444-8444-444444444444 "
            + "Correlation ID: 0e0e0e0e-5555-4555-8555-555555555555\r\n"
            + "Interactive authentication is needed. Please run:\r\n"
            + "az login --tenant \"" + Tenants.Other + "\"\r\n";
        // A quoted name goes up to the line's last quote: what's between goes with it.
        Assert.Equal(
            expected: AuthError.SignedOut(message:
                "AADSTS50020: User account '<account>' from identity provider 'live.com' does not exist in tenant '<name>'. "
                + "Trace ID: <id> Correlation ID: <id>"),
            actual: AzureCLITokenProvider.ErrorFromOutput(output: output));
        // A directory's ID where it says to sign in, and one it would cut short: neither is left, nor any part of one. A
        // quoted ID stays an ID.
        Assert.Equal(
            expected: AuthError.SignedOut(message: "Please run 'az login --tenant \"<id>\"' to setup account."),
            actual: AzureCLITokenProvider.ErrorFromOutput(output: "ERROR: Please run 'az login --tenant \"" + Tenants.Other + "\"' to setup account."));
        Assert.Equal(
            expected: AuthError.SignedOut(message: "AADSTS90002: Tenant '<id>' not found."),
            actual: AzureCLITokenProvider.ErrorFromOutput(output: "ERROR: AADSTS90002: Tenant '" + Tenants.Other + "' not found."));
        var cut = AzureCLITokenProvider.ErrorFromOutput(output: "ERROR: Please run 'az login'. " + new string(c: 'x', count: 266) + " " + Tenants.Other);
        Assert.DoesNotContain(expectedSubstring: Tenants.Other[..8], actualString: cut.Description, comparisonType: StringComparison.Ordinal);
        Assert.EndsWith(expectedEndString: " <id>", actualString: cut.Description, comparisonType: StringComparison.Ordinal);
        // A directory's name, however it's written, in single quotes or double, and whatever it holds: quotes of its own, or
        // no closing quote.
        Assert.Equal(
            expected: AuthError.Failed(message: "Directory '<name>' isn't available."),
            actual: AzureCLITokenProvider.ErrorFromOutput(output: "ERROR: Directory 'Fabrikam Example' isn't available."));
        Assert.Equal(
            expected: AuthError.Failed(message: "Directory '<name>' isn't available."),
            actual: AzureCLITokenProvider.ErrorFromOutput(output: "ERROR: Directory 'Fabrikam's Research Directory' isn't available."));
        Assert.Equal(
            expected: AuthError.Failed(message: "Directory \"<name>\" isn't available."),
            actual: AzureCLITokenProvider.ErrorFromOutput(output: "ERROR: Directory \"Fabrikam's Example\" isn't available."));
        Assert.Equal(
            expected: AuthError.SignedOut(message: "AADSTS50020: User account '<account>' does not exist in tenant '<name>'."),
            actual: AzureCLITokenProvider.ErrorFromOutput(output:
                "ERROR: AADSTS50020: User account 'robin@contoso.example' does not exist in tenant 'Fabrikam Students' Lab' "
                + "and cannot access the application '" + AzureCLITokenProvider.AzureDevOpsResource + "'."));
        Assert.Equal(
            expected: AuthError.Failed(message: "Directory '<name>'"),
            actual: AzureCLITokenProvider.ErrorFromOutput(output: "ERROR: Directory 'Fabrikam Example"));
        // A name it gives without quotes goes, to the line's end.
        Assert.Equal(
            expected: AuthError.SignedOut(message: "AADSTS500011: The resource principal named <id> was not found in the tenant named <name>"),
            actual: AzureCLITokenProvider.ErrorFromOutput(output:
                "ERROR: AADSTS500011: The resource principal named " + AzureCLITokenProvider.AzureDevOpsResource
                + " was not found in the tenant named Fabrikam Example. This can happen if the application has not been installed by the "
                + "administrator of the tenant or consented to by any user in the tenant."));
    }

    // Requests

    [Fact]
    public async Task ReadsAnOrganizationInAnotherDirectoryWithATokenFromThere()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        tokens.SignInTo(tenant: Tenants.Other);
        server.On(path: "/_apis/connectionData", json: Me);
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        using var client = server.Client(tokens: tokens);
        Assert.Equal(expected: "ME", actual: (await ConnectionDataAsync(client: client, organization: "fabrikam")).AuthenticatedUser.Id);
        // Rejected with a token from your directory, which isn't fabrikam's, then read with one from fabrikam's.
        Assert.Equal(expected: [Tenants.Home, Tenants.Other], actual: server.Requests.Select(selector: request => request.Tenant));
        // From then on, with one from there right away, however its name is spelled.
        await ConnectionDataAsync(client: client, organization: "Fabrikam");
        Assert.Equal(expected: [Tenants.Home, Tenants.Other, Tenants.Other], actual: server.Requests.Select(selector: request => request.Tenant));
        Assert.Equal(expected: [null, Tenants.Other, Tenants.Other], actual: tokens.Asked);
        Assert.Equal(expected: 0, actual: tokens.Invalidations);
    }

    [Fact]
    public async Task SaysWhenTheAzureCLIIsntSignedInToAnOrganizationsDirectory()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        server.On(path: "/_apis/connectionData", json: Me);
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        using var client = server.Client(tokens: tokens);
        var error = await Assert.ThrowsAsync<ADOException>(testCode: () => ConnectionDataAsync(client: client, organization: "fabrikam"));
        Assert.Equal(expected: ADOError.OtherDirectory(organization: "fabrikam", tenant: Tenants.Other), actual: error.Error);
        // Not a sign-in a fresh token of yours fixes: nothing more is sent once the Azure CLI can't give one from there.
        Assert.Single(collection: server.Requests);
        Assert.Equal(expected: 0, actual: tokens.Invalidations);
        // Until it can, each try asks Azure DevOps where it is, which may have changed, once.
        error = await Assert.ThrowsAsync<ADOException>(testCode: () => ConnectionDataAsync(client: client, organization: "fabrikam"));
        Assert.Equal(expected: ADOErrorKind.OtherDirectory, actual: error.Error.Kind);
        Assert.Equal(expected: 2, actual: server.Requests.Count);
        // What it says names neither the organization nor its directory: it goes where problems go.
        Assert.Equal(expected: "The organization is in a directory your Azure CLI isn't signed in to.", actual: error.Error.Description);
        // Once the Azure CLI is signed in there, it's read.
        tokens.SignInTo(tenant: Tenants.Other);
        Assert.Equal(expected: "ME", actual: (await ConnectionDataAsync(client: client, organization: "fabrikam")).AuthenticatedUser.Id);
    }

    [Fact]
    public async Task FollowsAnOrganizationThatMovesToAnotherDirectory()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        tokens.SignInTo(tenant: Tenants.Other);
        tokens.SignInTo(tenant: Tenants.Third);
        server.On(path: "/_apis/connectionData", json: Me);
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        using var client = server.Client(tokens: tokens);
        await ConnectionDataAsync(client: client, organization: "fabrikam");
        // It moves to the third directory, and the Azure CLI signs out of the one it was in.
        server.Put(organization: "fabrikam", tenant: Tenants.Third);
        tokens.SignOutOf(tenant: Tenants.Other);
        await ConnectionDataAsync(client: client, organization: "fabrikam");
        Assert.Equal(expected: [Tenants.Home, Tenants.Other, Tenants.Home, Tenants.Third], actual: server.Requests.Select(selector: request => request.Tenant));
        // Still signed in to the one it was in, it's followed all the same.
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        tokens.SignInTo(tenant: Tenants.Other);
        await ConnectionDataAsync(client: client, organization: "fabrikam");
        Assert.Equal(expected: [Tenants.Third, Tenants.Other], actual: server.Requests.Select(selector: request => request.Tenant).TakeLast(count: 2));
    }

    [Fact]
    public async Task ATokenRejectedByItsOwnDirectoryIsStillUnauthorized()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        // Azure DevOps names the token's own directory: you're not a member, or the token is stale.
        server.On(
            path: "/_apis/connectionData",
            reply: _ => StubReply.Code(status: 401, headers: new Dictionary<string, string> { ["X-VSS-ResourceTenant"] = Tenants.Home.ToUpperInvariant() }));
        using var client = server.Client(tokens: tokens);
        var error = await Assert.ThrowsAsync<ADOException>(testCode: () => ConnectionDataAsync(client: client, organization: "contoso"));
        Assert.Equal(expected: ADOError.Unauthorized, actual: error.Error);
        Assert.Equal(expected: [null, null], actual: tokens.Asked);
        Assert.Equal(expected: 1, actual: tokens.Invalidations);
    }

    [Fact]
    public void OnlyTenantIDsNameDirectories()
    {
        Assert.Equal(expected: [Tenants.Other, Tenants.Third], actual: ADOClient.ResourceTenants(header: Tenants.Other.ToUpperInvariant() + ", " + Tenants.Third));
        Assert.Empty(collection: ADOClient.ResourceTenants(header: "00000000-0000-0000-0000-000000000000"));
        // Nothing else goes on to `az login --tenant`.
        Assert.Empty(collection: ADOClient.ResourceTenants(header: "contoso & calc"));
        Assert.Empty(collection: ADOClient.ResourceTenants(header: string.Empty));
        Assert.Empty(collection: ADOClient.ResourceTenants(header: null));

        using var elsewhere = Rejected(tenants: [Tenants.Other]);
        var yours = new AccessToken(Value: "t", ExpiresOn: DateTimeOffset.MaxValue, Tenant: Tenants.Home);
        var theirs = new AccessToken(Value: "t", ExpiresOn: DateTimeOffset.MaxValue, Tenant: Tenants.Other);
        Assert.Equal(expected: Tenants.Other, actual: ADOClient.OtherDirectory(response: elsewhere, token: yours));
        Assert.Null(@object: ADOClient.OtherDirectory(response: elsewhere, token: theirs));
        // A token that doesn't say its directory can't be told from the organization's.
        Assert.Null(@object: ADOClient.OtherDirectory(response: elsewhere, token: new AccessToken(Value: "t", ExpiresOn: DateTimeOffset.MaxValue)));
        // The header said twice is one list.
        using var twice = Rejected(tenants: [Tenants.Third, Tenants.Home]);
        Assert.Null(@object: ADOClient.OtherDirectory(response: twice, token: yours));

        static HttpResponseMessage Rejected(IEnumerable<string> tenants)
        {
            var response = new HttpResponseMessage(statusCode: HttpStatusCode.Unauthorized);
            foreach (var tenant in tenants)
            {
                response.Headers.TryAddWithoutValidation(name: "X-VSS-ResourceTenant", value: tenant);
            }
            return response;
        }
    }

    [Fact]
    public void TellsWhichOrganizationARequestReads()
    {
        Assert.Equal(expected: "fabrikam", actual: ADOClient.OrganizationOf(url: ADOEndpoint.ConnectionData(organization: "fabrikam")));
        Assert.Equal(expected: "contoso", actual: ADOClient.OrganizationOf(url: ADOEndpoint.Threads(organization: "contoso", projectId: "p1", repositoryId: "r1", pullRequestId: 7)));
        Assert.Null(@object: ADOClient.OrganizationOf(url: ADOEndpoint.Profile));
        Assert.Null(@object: ADOClient.OrganizationOf(url: ADOEndpoint.Accounts(memberId: "alias")));
    }

    // What's wrong

    [Fact]
    public void NamesTheOrganizationsInADirectoryToSignInTo()
    {
        var problem = Assert.IsType<PulseProblem>(@object: PulseProblem.FromFailures(failures:
        [
            ("fabrikam", ADOError.OtherDirectory(organization: "fabrikam", tenant: Tenants.Other)),
            ("locked", ADOError.Forbidden),
            ("northwind", ADOError.OtherDirectory(organization: "northwind", tenant: Tenants.Other)),
            ("tailspin", ADOError.OtherDirectory(organization: "tailspin", tenant: Tenants.Third)),
        ]));
        var others = "Couldn't read locked (No access to this organization.), tailspin (The organization is in a directory your Azure CLI isn't signed in to.).";
        Assert.Equal(expected: PulseProblem.OtherDirectory(organizations: ["fabrikam", "northwind"], tenant: Tenants.Other, others: others), actual: problem);
        Assert.Equal(expected: "fabrikam and northwind are in a directory your Azure CLI isn't signed in to. " + others, actual: problem.Message);
        // A directory's ID only goes where signing in needs it.
        Assert.DoesNotContain(expectedSubstring: Tenants.Other, actualString: problem.Message, comparisonType: StringComparison.Ordinal);
        Assert.DoesNotContain(expectedSubstring: Tenants.Third, actualString: problem.Message, comparisonType: StringComparison.Ordinal);
        Assert.Equal(expected: Tenants.Other, actual: problem.SignInTenant);
        Assert.True(condition: problem.OffersSignIn);
        Assert.False(condition: problem.NeedsSignIn);

        var one = PulseProblem.From(error: ADOError.OtherDirectory(organization: "fabrikam", tenant: Tenants.Other), now: now);
        Assert.Equal(expected: "fabrikam is in a directory your Azure CLI isn't signed in to.", actual: one.Message);
        Assert.Equal(
            expected: new PulseProblem(Kind: PulseProblemKind.SomeOrganizations, Detail: "Couldn't read locked (No access to this organization.)."),
            actual: PulseProblem.FromFailures(failures: [("locked", ADOError.Forbidden)]));
        // One reason for each organization, however it's spelled.
        Assert.Equal(
            expected: "fabrikam is in a directory your Azure CLI isn't signed in to.",
            actual: PulseProblem.FromFailures(failures:
            [
                ("fabrikam", ADOError.OtherDirectory(organization: "fabrikam", tenant: Tenants.Other)),
                ("Fabrikam", ADOError.OtherDirectory(organization: "Fabrikam", tenant: Tenants.Other)),
            ])?.Message);
        Assert.Null(@object: PulseProblem.FromFailures(failures: []));
        // Named as Windows writes a list, three at most.
        Assert.Equal(
            expected: "adatum, contoso, fabrikam, and 1 more are in a directory your Azure CLI isn't signed in to.",
            actual: PulseProblem.OtherDirectory(organizations: ["adatum", "contoso", "fabrikam", "northwind"], tenant: Tenants.Other).Message);
        Assert.False(condition: PulseProblem.Offline.OffersSignIn);
        Assert.Null(@object: PulseProblem.Offline.SignInTenant);
    }

    [Fact]
    public void SignsInAgainInYourDirectoryWhenItWantsYouTo()
    {
        // Your directory wants you to sign in again, there, while the Azure CLI is still signed in to you in another.
        var again = PulseProblem.From(error: ADOError.FromAuth(error: AuthError.SignedOut(message: MultiFactor, tenant: Tenants.Home)), now: now);
        Assert.Equal(expected: PulseProblem.SignedOut(detail: MultiFactor, tenant: Tenants.Home), actual: again);
        Assert.True(condition: again.NeedsSignIn);
        Assert.Equal(expected: Tenants.Home, actual: again.SignInTenant);
        Assert.Equal(expected: "Sign in to the Azure CLI to see your pull requests.", actual: again.Message);
        // Signed out altogether, anyone may sign in, wherever their account is.
        var signedOut = PulseProblem.From(error: ADOError.FromAuth(error: AuthError.SignedOut(message: "Run az login")), now: now);
        Assert.Null(@object: signedOut.SignInTenant);
        Assert.True(condition: signedOut.OffersSignIn);
    }

    [Fact]
    public void AnOrganizationInADirectoryToSignInToSaysSoWhateverElseFailedThere()
    {
        // One of fabrikam's reads failed otherwise first.
        Assert.Equal(
            expected: PulseProblem.OtherDirectory(organizations: ["fabrikam"], tenant: Tenants.Other, others: "Couldn't read northwind (No access to this organization.)."),
            actual: PulseProblem.FromFailures(failures:
            [
                ("fabrikam", ADOError.Http(status: 500)),
                ("Fabrikam", ADOError.OtherDirectory(organization: "Fabrikam", tenant: Tenants.Other)),
                ("northwind", ADOError.Forbidden),
            ]));
    }

    // The engine

    [Fact]
    public async Task AnOrganizationInAnotherDirectoryDoesntHideTheOthers()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1, title: "Yours in contoso")]);
        server.ServeOrganization(organization: "fabrikam", mine: [Fixture.PullRequest(id: 2, title: "Yours in fabrikam")]);
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        using var client = server.Client(tokens: tokens);
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org, "fabrikam"] }, onChange: _ => { });
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 1)], actual: snapshot.Records.Select(selector: record => record.Id));
        Assert.Equal(expected: PulseProblem.OtherDirectory(organizations: ["fabrikam"], tenant: Tenants.Other), actual: snapshot.Problem);
        Assert.False(condition: snapshot.Problem?.NeedsSignIn);

        // Once the Azure CLI is signed in to fabrikam's directory too, it's read with the rest.
        tokens.SignInTo(tenant: Tenants.Other);
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 1), new PRKey(Organization: "fabrikam", Number: 2)], actual: snapshot.Records.Select(selector: record => record.Id));
        Assert.Null(@object: snapshot.Problem);
    }

    [Fact]
    public async Task WhenNothingCanBeReadItSaysWhichDirectoryToSignInTo()
    {
        var server = new StubServer();
        server.ServeOrganization(organization: "fabrikam");
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        server.On(path: "/northwind/_apis/connectionData", reply: _ => StubReply.Code(status: 500));
        using var client = server.Client(tokens: new FakeTokens(value: "made-up-token", home: Tenants.Home));
        var snapshot = await PulseEngine.LoadOnceAsync(
            client: client, configuration: new PulseEngineConfiguration { Organizations = ["fabrikam", "northwind"] }, cancellationToken: Cancellation);
        Assert.Equal(
            expected: PulseProblem.OtherDirectory(organizations: ["fabrikam"], tenant: Tenants.Other, others: "Couldn't read northwind (Azure DevOps answered with HTTP 500.)."),
            actual: snapshot.Problem);
    }

    [Fact]
    public async Task APullRequestYouWatchInAnotherDirectorySaysSoAndIsReadOnceSignedInThere()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        server.ServeOrganization(mine: [Fixture.PullRequest(id: 1)]);
        server.On(path: "/fabrikam/_apis/connectionData", json: new JsonObject { ["authenticatedUser"] = new JsonObject { ["id"] = Fixture.Me.ToUpperInvariant() } });
        server.On(path: "/fabrikam/_apis/git/pullrequests/9", json: Fixture.PullRequest(id: 9, title: "Theirs", author: People.Sam));
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        using var client = server.Client(tokens: tokens);
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org] }, onChange: _ => { });
        engine.SetLinkedPullRequests(keys: new HashSet<PRKey> { new(Organization: "fabrikam", Number: 9) });
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 1)], actual: snapshot.Records.Select(selector: record => record.Id));
        Assert.Equal(expected: PulseProblem.OtherDirectory(organizations: ["fabrikam"], tenant: Tenants.Other), actual: snapshot.Problem);
        // Signed in there, it's read at the next refresh, rather than an hour later.
        tokens.SignInTo(tenant: Tenants.Other);
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 1), new PRKey(Organization: "fabrikam", Number: 9)], actual: snapshot.Records.Select(selector: record => record.Id));
        Assert.Null(@object: snapshot.Problem);
    }

    [Fact]
    public async Task PullRequestsYouWatchInAnotherDirectoryDontKeepTheOthersWaiting()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        ServeTheirs(server: server, number: 11);
        // adatum's ten come first, as many as a refresh reads.
        server.Put(organization: "adatum", tenant: Tenants.Other);
        using var client = server.Client(tokens: tokens);
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration(), onChange: _ => { });
        engine.SetLinkedPullRequests(keys: Enumerable.Range(start: 1, count: 10).Select(selector: number => new PRKey(Organization: "adatum", Number: number)).Append(element: new PRKey(Organization: Fixture.Org, Number: 11)).ToHashSet());
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 11)], actual: snapshot.Records.Select(selector: record => record.Id));
        Assert.Equal(expected: PulseProblem.OtherDirectory(organizations: ["adatum"], tenant: Tenants.Other), actual: snapshot.Problem);
        // One of adatum's was tried; the rest waited without taking contoso's turn.
        Assert.Single(collection: server.Requests, predicate: request => request.Path.StartsWith(value: "/adatum/", comparisonType: StringComparison.Ordinal));
    }

    [Fact]
    public async Task OrganizationsWaitingOnASignInDontTakeTheReadsOfPullRequestsSentToYou()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        ServeTheirs(server: server, number: 11);
        // Ten organizations in a directory to sign in to come first, as many as a refresh reads.
        var elsewhere = Enumerable.Range(start: 1, count: 10).Select(selector: number => "adatum" + Fixture.Text(number: number)).ToList();
        foreach (var organization in elsewhere)
        {
            server.Put(organization: organization, tenant: Tenants.Other);
        }
        using var client = server.Client(tokens: tokens);
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration(), onChange: _ => { });
        engine.SetLinkedPullRequests(keys: elsewhere.Select(selector: organization => new PRKey(Organization: organization, Number: 1)).Append(element: new PRKey(Organization: Fixture.Org, Number: 11)).ToHashSet());
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 11)], actual: snapshot.Records.Select(selector: record => record.Id));
        // Each was tried once, and is said.
        foreach (var organization in elsewhere)
        {
            Assert.Single(collection: server.Requests, predicate: request => request.Path.StartsWith(value: "/" + organization + "/", comparisonType: StringComparison.Ordinal));
        }
        Assert.Equal(expected: Tenants.Other, actual: snapshot.Problem?.SignInTenant);
    }

    [Fact]
    public async Task PullRequestsSentToYouAreReadWhileEveryOrganizationYouWatchWaitsOnASignIn()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        server.ServeOrganization(organization: "fabrikam", mine: [Fixture.PullRequest(id: 1, title: "Yours in fabrikam")]);
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        ServeTheirs(server: server, number: 11);
        using var client = server.Client(tokens: tokens);
        var interval = TimeSpan.FromMinutes(value: 5);
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = ["fabrikam"], Interval = interval }, onChange: _ => { });
        engine.SetLinkedPullRequests(keys: new HashSet<PRKey> { new(Organization: Fixture.Org, Number: 11) });
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        var snapshot = engine.CurrentSnapshot();
        // fabrikam, the one you watch, waits on a sign-in to its directory; the one sent to you from contoso is read.
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 11)], actual: snapshot.Records.Select(selector: record => record.Id));
        Assert.Equal(expected: PulseProblem.OtherDirectory(organizations: ["fabrikam"], tenant: Tenants.Other), actual: snapshot.Problem);
        // Something was read: the next refresh comes as often as usual.
        Assert.Equal(expected: interval, actual: engine.NextDelay());
    }

    [Fact]
    public async Task AskingToSlowDownComesBeforeADirectoryToSignInTo()
    {
        var server = new StubServer();
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        server.On(path: "/northwind/_apis/connectionData", reply: _ => SlowDown());
        using var client = server.Client(tokens: new FakeTokens(value: "made-up-token", home: Tenants.Home));
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = ["fabrikam", "northwind"] }, onChange: _ => { });
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        // Nothing goes out until then, and nothing can be read either, signed in there or not.
        Assert.Equal(expected: PulseProblemKind.Throttled, actual: engine.CurrentSnapshot().Problem?.Kind);
        Assert.True(condition: engine.NextDelay() > TimeSpan.FromSeconds(value: 100));
    }

    [Fact]
    public async Task AskingToSlowDownComesFirstWhileOtherOrganizationsAreRead()
    {
        var server = new StubServer();
        server.ServeOrganization();
        server.ServeOrganization(organization: "northwind");
        var slowDown = false;
        server.On(path: "/northwind/_apis/git/pullrequests", reply: _ => Volatile.Read(location: ref slowDown) ? SlowDown() : StubReply.Json(body: Fixture.List(items: [])));
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        using var client = server.Client(tokens: new FakeTokens(value: "made-up-token", home: Tenants.Home));
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org, "fabrikam", "northwind"] }, onChange: _ => { });
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: Tenants.Other, actual: engine.CurrentSnapshot().Problem?.SignInTenant);
        // contoso's lists are read; northwind's are asked to wait: that comes first, over fabrikam's directory.
        Volatile.Write(location: ref slowDown, value: true);
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: PulseProblemKind.Throttled, actual: engine.CurrentSnapshot().Problem?.Kind);
        Assert.True(condition: engine.NextDelay() > TimeSpan.FromSeconds(value: 100));
    }

    [Fact]
    public async Task AskingToSlowDownForAPullRequestSentToYouComesFirstToo()
    {
        var server = new StubServer();
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        server.On(path: "/contoso/_apis/connectionData", reply: _ => SlowDown());
        using var client = server.Client(tokens: new FakeTokens(value: "made-up-token", home: Tenants.Home));
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = ["fabrikam"] }, onChange: _ => { });
        engine.SetLinkedPullRequests(keys: new HashSet<PRKey> { new(Organization: Fixture.Org, Number: 11) });
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: PulseProblemKind.Throttled, actual: engine.CurrentSnapshot().Problem?.Kind);
        Assert.True(condition: engine.NextDelay() > TimeSpan.FromSeconds(value: 100));
    }

    [Fact]
    public async Task OrganizationsWaitingOnASignInArentAskedForMore()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        tokens.SignInTo(tenant: Tenants.Other);
        server.ServeOrganization(organization: "fabrikam", mine: [Fixture.PullRequest(id: 1, title: "Yours in fabrikam")]);
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        var clock = new TestClock(start: now);
        using var client = server.Client(tokens: tokens, time: clock);
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = ["fabrikam"] }, onChange: _ => { }, time: clock);
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: [new PRKey(Organization: "fabrikam", Number: 1)], actual: engine.CurrentSnapshot().Records.Select(selector: record => record.Id));

        // An hour later, the Azure CLI signed out of fabrikam's directory: its pull request stays as it was read, and its
        // details, due again, aren't asked for.
        tokens.SignOutOf(tenant: Tenants.Other);
        clock.Set(time: now.AddHours(hours: 1));
        var before = server.Requests.Count;
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: [new PRKey(Organization: "fabrikam", Number: 1)], actual: engine.CurrentSnapshot().Records.Select(selector: record => record.Id));
        Assert.DoesNotContain(
            collection: server.Requests.Skip(count: before),
            filter: request => request.Path.Contains(value: "/_apis/policy/evaluations", comparisonType: StringComparison.Ordinal)
                || request.Path.Contains(value: "/threads", comparisonType: StringComparison.Ordinal));
    }

    /// Nor are where its failed builds failed, or the pipelines after its merges, until you've signed in there: then they
    /// are, at once.
    [Fact]
    public async Task OrganizationsWaitingOnASignInArentAskedForTheirBuildsOrMerges()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        tokens.SignInTo(tenant: Tenants.Other);
        var merged = Fixture.PullRequest(id: 3, title: "Merged", status: "completed", closed: now.AddMinutes(minutes: -5));
        merged["lastMergeCommit"] = new JsonObject { ["commitId"] = "m1" };
        server.ServeOrganization(organization: "fabrikam", mine: [Fixture.PullRequest(id: 1, created: now.AddDays(days: -1))], completed: [merged]);
        server.On(
            path: "/_apis/policy/evaluations",
            json: Fixture.List(items:
            [
                Fixture.Evaluation(
                    type: "Build", status: "rejected", settings: new JsonObject { ["displayName"] = "web-ci" }, context: new JsonObject { ["buildId"] = 4 }, completed: now.AddMinutes(minutes: -10)),
            ]));
        // Where build 4 failed can't be read yet, so it's tried again; and the runs on the merge haven't started.
        server.On(path: "/builds/4/timeline", reply: _ => StubReply.Code(status: 500));
        server.On(path: "/_apis/build/builds", json: Fixture.List(items: []), query: new Dictionary<string, string> { ["repositoryId"] = "r1" });
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        var clock = new TestClock(start: now);
        using var client = server.Client(tokens: tokens, time: clock);
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = ["fabrikam"] }, onChange: _ => { }, time: clock);
        int Timelines() => server.Requests.Count(predicate: request => request.Path.EndsWith(value: "/builds/4/timeline", comparisonType: StringComparison.Ordinal));
        int RunLookups() => server.Requests.Count(predicate: request => request.Path.EndsWith(value: "/_apis/build/builds", comparisonType: StringComparison.Ordinal));

        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: (1, 1), actual: (Timelines(), RunLookups()));

        // Signed out of fabrikam's directory, a refresh later both would be due.
        tokens.SignOutOf(tenant: Tenants.Other);
        clock.Set(time: now.AddMinutes(minutes: 2));
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: (1, 1), actual: (Timelines(), RunLookups()));
        Assert.Equal(expected: PulseProblemKind.OtherDirectory, actual: engine.CurrentSnapshot().Problem?.Kind);
        // What's known of them stays.
        Assert.Equal(
            expected: [new PRKey(Organization: "fabrikam", Number: 1), new PRKey(Organization: "fabrikam", Number: 3)],
            actual: engine.CurrentSnapshot().Records.Select(selector: record => record.Id));

        tokens.SignInTo(tenant: Tenants.Other);
        clock.Set(time: now.AddMinutes(minutes: 3));
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: (2, 2), actual: (Timelines(), RunLookups()));
        Assert.Null(@object: engine.CurrentSnapshot().Problem);
    }

    [Fact]
    public async Task AskingToSlowDownLookingUpAPullRequestThatLeftYourListsComesFirstToo()
    {
        var server = new StubServer();
        server.ServeOrganization();
        var gone = false;
        server.On(
            path: "/contoso/_apis/git/pullrequests",
            reply: _ => StubReply.Json(body: Fixture.List(items: Volatile.Read(location: ref gone) ? [] : [Fixture.PullRequest(id: 1, title: "Yours")])),
            query: new Dictionary<string, string> { ["searchCriteria.creatorId"] = Fixture.Me, ["searchCriteria.status"] = "active" });
        server.On(path: "/contoso/_apis/git/pullrequests/1", reply: _ => SlowDown());
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        using var client = server.Client(tokens: new FakeTokens(value: "made-up-token", home: Tenants.Home));
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Organizations = [Fixture.Org, "fabrikam"] }, onChange: _ => { });
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: [new PRKey(Organization: Fixture.Org, Number: 1)], actual: engine.CurrentSnapshot().Records.Select(selector: record => record.Id));

        // Your pull request leaves your lists, and looking it up is asked to wait: that comes first, over fabrikam's
        // directory, though nothing else is read after it.
        Volatile.Write(location: ref gone, value: true);
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: PulseProblemKind.Throttled, actual: engine.CurrentSnapshot().Problem?.Kind);
    }

    [Fact]
    public async Task PullRequestsSentToYouThatCantBeReadAgainAreLookedAtWithinAMinute()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        tokens.SignInTo(tenant: Tenants.Other);
        server.On(path: "/fabrikam/_apis/connectionData", json: new JsonObject { ["authenticatedUser"] = new JsonObject { ["id"] = Fixture.Me.ToUpperInvariant() } });
        server.On(path: "/fabrikam/_apis/git/pullrequests/9", json: Fixture.PullRequest(id: 9, title: "Theirs", author: People.Sam));
        server.On(path: "/_apis/policy/evaluations", json: Fixture.List(items: []));
        server.On(path: "/threads", json: Fixture.List(items: []));
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        using var client = server.Client(tokens: tokens);
        var interval = TimeSpan.FromMinutes(value: 5);
        using var engine = new PulseEngine(client: client, configuration: new PulseEngineConfiguration { Interval = interval }, onChange: _ => { });
        engine.SetLinkedPullRequests(keys: new HashSet<PRKey> { new(Organization: "fabrikam", Number: 9) });
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        Assert.Equal(expected: [new PRKey(Organization: "fabrikam", Number: 9)], actual: engine.CurrentSnapshot().Records.Select(selector: record => record.Id));
        Assert.Equal(expected: interval, actual: engine.NextDelay());

        // The Azure CLI signs out of fabrikam's directory: the pull request stays as it was last read, but nothing was.
        tokens.SignOutOf(tenant: Tenants.Other);
        await engine.RefreshNowAsync(cancellationToken: Cancellation);
        var snapshot = engine.CurrentSnapshot();
        Assert.Equal(expected: [new PRKey(Organization: "fabrikam", Number: 9)], actual: snapshot.Records.Select(selector: record => record.Id));
        Assert.Equal(expected: PulseProblem.OtherDirectory(organizations: ["fabrikam"], tenant: Tenants.Other), actual: snapshot.Problem);
        Assert.Equal(expected: TimeSpan.FromMinutes(value: 1), actual: engine.NextDelay());
    }

    // Finding and adding organizations

    [Fact]
    public async Task FindsYourPullRequestsInAnotherDirectoryOnceSignedInThere()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        server.ServeOrganization(organization: "fabrikam", mine: [Fixture.PullRequest(id: 1)]);
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        using var client = server.Client(tokens: tokens);
        // Not signed in there: nothing of yours to show, rather than a failure to try again.
        var probe = await OrganizationDiscovery.ProbeAsync(organizations: ["fabrikam"], client: client, cancellationToken: Cancellation);
        Assert.Empty(collection: probe.WithPullRequests);
        Assert.Empty(collection: probe.Failures);
        tokens.SignInTo(tenant: Tenants.Other);
        probe = await OrganizationDiscovery.ProbeAsync(organizations: ["fabrikam"], client: client, cancellationToken: Cancellation);
        Assert.Equal(expected: ["fabrikam"], actual: probe.WithPullRequests);
    }

    [Fact]
    public async Task ChecksAnOrganizationAsYouAddIt()
    {
        var server = new StubServer();
        var tokens = new FakeTokens(value: "made-up-token", home: Tenants.Home);
        server.On(path: "/_apis/profile/profiles/me", json: new JsonObject { ["id"] = "profile-id", ["publicAlias"] = "alias" });
        server.On(
            path: "/_apis/accounts",
            json: Fixture.List(items: [new JsonObject { ["accountName"] = "contoso" }, new JsonObject { ["accountName"] = "Locked" }]),
            query: new Dictionary<string, string> { ["memberId"] = "alias" });
        server.On(path: "/contoso/_apis/connectionData", json: Me);
        server.On(path: "/locked/_apis/connectionData", reply: _ => StubReply.Code(status: 403));
        // Another organization in your directory, which isn't yours: a project's name, perhaps.
        server.On(path: "/web/_apis/connectionData", reply: _ => StubReply.Code(status: 401));
        server.On(path: "/offline/_apis/connectionData", reply: _ => StubReply.Offline());
        server.Put(organization: "fabrikam", tenant: Tenants.Other);
        // A project's name, entered as an organization's, which is another organization's, in another directory.
        server.Put(organization: "shop", tenant: Tenants.Third);
        using var client = server.Client(tokens: tokens);

        Assert.Equal(expected: OrganizationAccess.Readable, actual: await AccessAsync(client: client, organization: "contoso"));
        Assert.Equal(expected: OrganizationAccess.OtherDirectory(tenant: Tenants.Other), actual: await AccessAsync(client: client, organization: "fabrikam"));
        Assert.Equal(expected: OrganizationAccess.OtherDirectory(tenant: Tenants.Third), actual: await AccessAsync(client: client, organization: "shop"));
        Assert.Equal(expected: OrganizationAccess.NotYours, actual: await AccessAsync(client: client, organization: "web"));
        // Azure DevOps has none by that name.
        Assert.Equal(expected: OrganizationAccess.NotYours, actual: await AccessAsync(client: client, organization: "nowhere"));
        Assert.Equal(expected: OrganizationAccess.Unreadable(error: ADOError.Forbidden), actual: await AccessAsync(client: client, organization: "locked"));
        Assert.Equal(expected: OrganizationAccess.Unchecked(error: ADOError.Offline), actual: await AccessAsync(client: client, organization: "offline"));
        Assert.All(collection: server.Requests, action: request => Assert.Equal(expected: HttpMethod.Get, actual: request.Method));
        // Your organizations are asked for only when an organization can't be read otherwise.
        Assert.Equal(expected: 2, actual: server.Requests.Count(predicate: request => request.Path.EndsWith(value: "/_apis/accounts", comparisonType: StringComparison.Ordinal)));
    }

    [Fact]
    public async Task AnOrganizationThatCantBeToldYoursIsWatched()
    {
        var server = new StubServer();
        server.On(path: "/_apis/profile/profiles/me", reply: _ => StubReply.Offline());
        server.On(path: "/locked/_apis/connectionData", reply: _ => StubReply.Code(status: 403));
        using var client = server.Client(tokens: new FakeTokens(value: "made-up-token", home: Tenants.Home));
        // Its list says why it can't be read, once it's watched.
        var access = await AccessAsync(client: client, organization: "locked");
        Assert.Equal(expected: OrganizationAccess.Unchecked(error: ADOError.Offline), actual: access);
        Assert.True(condition: access.Watches);
        Assert.Null(@object: access.Explanation(organization: "locked"));
    }

    [Fact]
    public void SaysWhyAnOrganizationIsntAddedAndWhereAProjectsOrganizationIs()
    {
        const string hint = "If shop is a project, its organization is the first part of its link: dev.azure.com/organization/shop.";
        var elsewhere = OrganizationAccess.OtherDirectory(tenant: Tenants.Third);
        var inAnotherDirectory = Assert.NotNull(value: elsewhere.Explanation(organization: "shop"));
        Assert.Equal(expected: "shop is in a directory your Azure CLI isn't signed in to", actual: inAnotherDirectory.Title);
        Assert.Equal(expected: "Sign in to it, and BriefBar reads shop with your other organizations. " + hint, actual: inAnotherDirectory.Detail);
        Assert.DoesNotContain(expectedSubstring: Tenants.Third, actualString: inAnotherDirectory.Title + inAnotherDirectory.Detail, comparisonType: StringComparison.Ordinal);
        Assert.True(condition: elsewhere.Watches);
        Assert.Equal(expected: Tenants.Third, actual: elsewhere.SignInTenant);

        var notYours = Assert.NotNull(value: OrganizationAccess.NotYours.Explanation(organization: "shop"));
        Assert.Equal(expected: "shop isn't one of your organizations", actual: notYours.Title);
        Assert.Equal(expected: "BriefBar didn't add it. " + hint, actual: notYours.Detail);
        Assert.False(condition: OrganizationAccess.NotYours.Watches);

        var forbidden = OrganizationAccess.Unreadable(error: ADOError.Forbidden);
        var unreadable = Assert.NotNull(value: forbidden.Explanation(organization: "locked"));
        Assert.Equal(expected: "Your sign-in can't read locked", actual: unreadable.Title);
        Assert.Equal(expected: "BriefBar didn't add it. No access to this organization.", actual: unreadable.Detail);
        Assert.False(condition: forbidden.Watches);

        // Readable, or not checked for now: it's watched without a word, and its list says what's wrong.
        Assert.Null(@object: OrganizationAccess.Readable.Explanation(organization: "contoso"));
        Assert.Null(@object: OrganizationAccess.Unchecked(error: ADOError.Offline).Explanation(organization: "contoso"));
        Assert.True(condition: OrganizationAccess.Unchecked(error: ADOError.Offline).Watches);
        Assert.Null(@object: OrganizationAccess.Readable.SignInTenant);
    }

    static JsonObject Me => new() { ["authenticatedUser"] = new JsonObject { ["id"] = "ME" } };

    /// A provider that runs `cli`, as `az.cmd` where the PATH says, knowing your sign-in's directory, and where your
    /// account is from, when they're kept from before.
    static AzureCLITokenProvider Provider(FakeAzureCLI cli, string? homeTenant = null, string? homeAccountTenant = null) => new(
        locator: new AzureCLILocator(environment: new Dictionary<string, string?> { ["PATH"] = @"C:\Tools" }, exists: path => path == @"C:\Tools\az.cmd"),
        runner: cli,
        time: new TestClock(start: now),
        homeTenant: homeTenant,
        homeAccountTenant: homeAccountTenant);

    static Task<ADOConnectionData> ConnectionDataAsync(ADOClient client, string organization) =>
        client.GetAsync(url: ADOEndpoint.ConnectionData(organization: organization), read: ADOConnectionData.Read, cancellationToken: Cancellation);

    static Task<OrganizationAccess> AccessAsync(ADOClient client, string organization) =>
        OrganizationDiscovery.AccessAsync(organization: organization, client: client, cancellationToken: Cancellation);

    /// Azure DevOps asks BriefBar to wait two minutes.
    static StubReply SlowDown() => StubReply.Code(status: 429, headers: new Dictionary<string, string> { ["Retry-After"] = "120" });

    /// contoso, where someone else's pull request `number` was sent to you.
    static void ServeTheirs(StubServer server, int number)
    {
        server.On(path: "/contoso/_apis/connectionData", json: new JsonObject { ["authenticatedUser"] = new JsonObject { ["id"] = Fixture.Me.ToUpperInvariant() } });
        server.On(path: "/contoso/_apis/git/pullrequests/" + Fixture.Text(number: number), json: Fixture.PullRequest(id: number, title: "Theirs", author: People.Sam));
        server.On(path: "/_apis/policy/evaluations", json: Fixture.List(items: []));
        server.On(path: "/threads", json: Fixture.List(items: []));
    }
}
