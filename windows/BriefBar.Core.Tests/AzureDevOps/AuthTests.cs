using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests.AzureDevOps;

public sealed class AuthTests
{
    const string InstalledCLI = @"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd";
    const string InstalledCLIFor32Bits = @"C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd";

    [Fact]
    public void ParsesTheCLIToken()
    {
        var json = """{"accessToken": "abc", "expiresOn": "2026-10-21 10:31:46.000000", "expires_on": 1792564306, "tenant": "t", "tokenType": "Bearer"}""";
        var token = AzureCLITokenProvider.ParseToken(output: json, now: TestTimes.T(seconds: 0));
        Assert.Equal(expected: "abc", actual: token.Value);
        Assert.Equal(expected: DateTimeOffset.FromUnixTimeSeconds(seconds: 1_792_564_306), actual: token.ExpiresOn);
    }

    [Fact]
    public void FallsBackToTheLocalExpiryTime()
    {
        var token = AzureCLITokenProvider.ParseToken(output: """{"accessToken": "abc", "expiresOn": "2026-10-21 10:31:46.000000"}""", now: TestTimes.T(seconds: 0));
        var local = new DateTime(year: 2026, month: 10, day: 21, hour: 10, minute: 31, second: 46, kind: DateTimeKind.Unspecified);
        Assert.Equal(expected: new DateTimeOffset(dateTime: TimeZoneInfo.ConvertTimeToUtc(dateTime: local, sourceTimeZone: TimeZoneInfo.Local)), actual: token.ExpiresOn);

        var undated = AzureCLITokenProvider.ParseToken(output: """{"accessToken": "abc"}""", now: TestTimes.T(seconds: 0));
        Assert.Equal(expected: TestTimes.T(seconds: 30 * Make.Minute), actual: undated.ExpiresOn);
    }

    [Fact]
    public void ReadsWhoATokenIsFor()
    {
        var token = Jwt(claims: """{"tid":"T1","oid":"O-1","upn":"robin@contoso.com"}""");
        Assert.Equal(expected: "t1/o-1", actual: AccessToken.AccountInJwt(token: token));
        var output = new JsonObject { ["accessToken"] = token, ["expires_on"] = 1_792_564_306 }.ToJsonString();
        var parsed = AzureCLITokenProvider.ParseToken(output: output, now: TestTimes.T(seconds: 0));
        Assert.Equal(expected: "t1/o-1", actual: parsed.Account);
        Assert.Equal(expected: "/s", actual: AccessToken.AccountInJwt(token: Jwt(claims: """{"sub":"S"}""")));
        Assert.Null(@object: AccessToken.AccountInJwt(token: "opaque"));
        Assert.Null(@object: AccessToken.AccountInJwt(token: "a.b.c"));

        // An unsigned token: a header that says so, the claims, and a made-up signature, each in base64url.
        static string Jwt(string claims)
        {
            var payload = Convert.ToBase64String(inArray: Encoding.UTF8.GetBytes(s: claims)).Replace(oldChar: '+', newChar: '-').Replace(oldChar: '/', newChar: '_').TrimEnd(trimChar: '=');
            return "eyJhbGciOiJub25lIn0." + payload + ".c2ln";
        }
    }

    [Fact]
    public void RejectsOutputWithoutAToken()
    {
        var error = Assert.Throws<AuthException>(testCode: () => AzureCLITokenProvider.ParseToken(output: "{}", now: TestTimes.T(seconds: 0)));
        Assert.Equal(expected: AuthError.Failed(message: "The Azure CLI returned no token."), actual: error.Error);
    }

    [Theory]
    [InlineData("ERROR: Please run 'az login' to setup account.", true)]
    [InlineData("ERROR: AADSTS700082: The refresh token has expired due to inactivity.", true)]
    [InlineData("ERROR: User 'x' does not exist in MSAL token cache. Run `az login`.", true)]
    [InlineData("WARNING: something\nERROR: Connection reset by peer", false)]
    // The CLI ends its lines as Windows does.
    [InlineData("WARNING: something\r\nERROR: Connection reset by peer\r\n", false)]
    public void TellsASignedOutCLIFromOtherFailures(string output, bool signedOut)
    {
        var error = AzureCLITokenProvider.ErrorFromOutput(output: output);
        if (signedOut)
        {
            Assert.Equal(expected: AuthErrorKind.SignedOut, actual: error.Kind);
            Assert.False(condition: error.Message.StartsWith(value: "ERROR:", comparisonType: StringComparison.Ordinal));
        }
        else
        {
            Assert.Equal(expected: AuthError.Failed(message: "Connection reset by peer"), actual: error);
        }
    }

    /// The Mac's `addsTheUsualPlacesToPath`: a Mac app gets only the system's PATH, so the usual places are added to it.
    /// Windows gives BriefBar your PATH, which is left as it is: runs are kept quiet and out of the CLI's telemetry, and
    /// get only fixed words, which the batch file `az.cmd` may get.
    [Fact]
    public void KeepsRunsQuietAndLeavesThePathAlone()
    {
        Assert.Equal(
            expected: new Dictionary<string, string?>
            {
                ["AZURE_CORE_COLLECT_TELEMETRY"] = "false",
                ["AZURE_CORE_ONLY_SHOW_ERRORS"] = "true",
                ["AZURE_CORE_NO_COLOR"] = "true",
            },
            actual: AzureCLITokenProvider.Environment);
        Assert.DoesNotContain(collection: AzureCLITokenProvider.Environment.Keys, filter: name => string.Equals(a: name, b: "PATH", comparisonType: StringComparison.OrdinalIgnoreCase));
        Assert.Equal(
            expected: ["account", "get-access-token", "--resource", "499b84ac-1321-427f-aa17-267ca6975798", "--output", "json"],
            actual: AzureCLITokenProvider.Arguments);
        Assert.EndsWith(
            expectedEndString: "\" account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --output json\"",
            actualString: ProcessRunner.BatchCommandLine(batchFile: InstalledCLI, arguments: AzureCLITokenProvider.Arguments, keepOpen: false));
    }

    [Fact]
    public void LocatesTheCLI()
    {
        var present = new HashSet<string>(collection: [@"C:\Tools\az.cmd", @"D:\Custom\az.cmd"], comparer: StringComparer.Ordinal);
        var environment = new Dictionary<string, string?> { ["PATH"] = @"C:\Windows\System32;C:\Tools" };
        var usual = new AzureCLILocator(environment: environment, exists: present.Contains);
        Assert.Equal(expected: @"C:\Tools\az.cmd", actual: usual.Locate());
        var overridden = new AzureCLILocator(environment: new Dictionary<string, string?>(dictionary: environment) { ["BRIEFBAR_AZ"] = @"D:\Custom\az.cmd" }, exists: present.Contains);
        Assert.Equal(expected: @"D:\Custom\az.cmd", actual: overridden.Locate());
        var missing = new AzureCLILocator(environment: environment, exists: _ => false);
        Assert.Null(@object: missing.Locate());
    }

    /// Where `BRIEFBAR_AZ` says, if it's there, as on the Mac; then each folder of the PATH in turn, for each of the names
    /// `az` has, in the order of `PATHEXT`, but not a folder that isn't a full path, such as the current folder; then where
    /// its installer puts it.
    [Fact]
    public void LooksForTheCLIInWindowsOrder()
    {
        var asked = new List<string>();
        var locator = new AzureCLILocator(
            environment: new Dictionary<string, string?>
            {
                ["BRIEFBAR_AZ"] = @"D:\Gone\az.cmd",
                ["PATH"] = @"C:\First;""C:\Quoted Folder"";relative; ;C:\Last",
                ["ProgramFiles"] = @"C:\Program Files",
                ["ProgramFiles(x86)"] = @"C:\Program Files (x86)",
            },
            exists: path =>
            {
                asked.Add(item: path);
                return false;
            });
        Assert.Null(@object: locator.Locate());
        Assert.Equal(
            expected:
            [
                @"D:\Gone\az.cmd",
                @"C:\First\az.exe", @"C:\First\az.cmd", @"C:\First\az.bat",
                @"C:\Quoted Folder\az.exe", @"C:\Quoted Folder\az.cmd", @"C:\Quoted Folder\az.bat",
                @"C:\Last\az.exe", @"C:\Last\az.cmd", @"C:\Last\az.bat",
                InstalledCLI, InstalledCLIFor32Bits,
            ],
            actual: asked);
    }

    /// The Mac's `asksALoginShellAsALastResort`: on Windows, BriefBar may have started before the PATH had `az`, as when
    /// it was just installed, so it looks where the installer puts it, for 64-bit Windows, then for the 32-bit CLI.
    [Fact]
    public void LooksWhereTheInstallerPutsItWhenThePathDoesntHaveIt()
    {
        var environment = new Dictionary<string, string?>
        {
            ["PATH"] = @"C:\Windows\System32",
            ["ProgramFiles"] = @"C:\Program Files",
            ["ProgramFiles(x86)"] = @"C:\Program Files (x86)",
        };
        Assert.Equal(expected: InstalledCLIFor32Bits, actual: new AzureCLILocator(environment: environment, exists: path => path == InstalledCLIFor32Bits).Locate());
        Assert.Equal(expected: InstalledCLI, actual: new AzureCLILocator(environment: environment, exists: path => path is InstalledCLI or InstalledCLIFor32Bits).Locate());
    }

    [Fact]
    public async Task CachesTokensUntilTheyNearExpiry()
    {
        var cli = new FakeProcessRunner(answer: run => new ProcessResult(
            ExitCode: 0,
            Output: new JsonObject
            {
                ["accessToken"] = "token" + run.ToString(provider: CultureInfo.InvariantCulture),
                ["expires_on"] = TestTimes.T(seconds: run * 600.0).ToUnixTimeSeconds(),
            }.ToJsonString(),
            Error: string.Empty));
        var clock = new TestClock(start: TestTimes.T(seconds: 0));
        var provider = new AzureCLITokenProvider(
            locator: new AzureCLILocator(environment: new Dictionary<string, string?> { ["PATH"] = @"C:\Tools" }, exists: path => path == @"C:\Tools\az.cmd"),
            runner: cli,
            time: clock);
        var cancellationToken = TestContext.Current.CancellationToken;
        Assert.Equal(expected: "token1", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.Equal(expected: "token1", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        // Within five minutes of expiring, it asks again.
        clock.Set(time: TestTimes.T(seconds: 301));
        Assert.Equal(expected: "token2", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        provider.Invalidate();
        Assert.Equal(expected: "token3", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.Equal(expected: 3, actual: cli.Runs.Count);
        // Each time the `az` it found, with the fixed arguments, quietly, for a minute at most.
        Assert.All(collection: cli.Runs, action: run =>
        {
            Assert.Equal(expected: @"C:\Tools\az.cmd", actual: run.Program);
            Assert.Equal(expected: AzureCLITokenProvider.Arguments, actual: run.Arguments);
            Assert.Equal(expected: AzureCLITokenProvider.Environment, actual: run.Environment);
            Assert.Equal(expected: TimeSpan.FromMinutes(value: 1), actual: run.Timeout);
        });
        Assert.Equal(expected: @"C:\Tools\az.cmd", actual: provider.Program);
    }

    [Fact]
    public async Task ReportsAMissingCLI()
    {
        var cli = new FakeProcessRunner(answer: _ => new ProcessResult(ExitCode: 0, Output: """{"accessToken": "abc"}""", Error: string.Empty));
        var provider = new AzureCLITokenProvider(locator: new AzureCLILocator(environment: new Dictionary<string, string?>()), runner: cli);
        var error = await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(expected: AuthError.CliNotFound, actual: error.Error);
        Assert.Empty(collection: cli.Runs);
    }

    /// With `ProcessRunner`, and a made-up `az.cmd` that answers with what it got: its arguments, and the variables that
    /// keep it quiet.
    [Fact]
    public async Task GetsATokenFromTheCLIsBatchFile()
    {
        using var folder = new TemporaryFolder();
        File.WriteAllText(
            path: folder.Combine("az.cmd"),
            contents: "@echo {\"accessToken\": \"%*;%AZURE_CORE_COLLECT_TELEMETRY%;%AZURE_CORE_ONLY_SHOW_ERRORS%;%AZURE_CORE_NO_COLOR%\", \"expires_on\": 1792564306}\r\n");
        var provider = new AzureCLITokenProvider(
            locator: new AzureCLILocator(environment: new Dictionary<string, string?> { ["PATH"] = folder.Path }), time: new TestClock(start: TestTimes.T(seconds: 0)));

        var token = await provider.TokenAsync(cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(expected: "account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --output json;false;true;true", actual: token.Value);
        Assert.Equal(expected: DateTimeOffset.FromUnixTimeSeconds(seconds: 1_792_564_306), actual: token.ExpiresOn);
        Assert.Equal(expected: folder.Combine("az.cmd"), actual: provider.Program);
    }

    /// As on the Mac, a CLI that can't run any more, as once it's uninstalled or moved, is looked for again next time:
    /// `ProcessRunner` reports a batch file that isn't there as a program that isn't there.
    [Fact]
    public async Task LooksForTheCLIAgainOnceItsGone()
    {
        using var folder = new TemporaryFolder();
        var first = Directory.CreateDirectory(path: folder.Combine("first")).FullName;
        var second = Directory.CreateDirectory(path: folder.Combine("second")).FullName;
        File.WriteAllText(path: Path.Combine(path1: first, path2: "az.cmd"), contents: "@echo {\"accessToken\": \"first\", \"expires_on\": 1792564306}\r\n");
        var provider = new AzureCLITokenProvider(
            locator: new AzureCLILocator(environment: new Dictionary<string, string?> { ["PATH"] = first + ";" + second }), time: new TestClock(start: TestTimes.T(seconds: 0)));
        var cancellationToken = TestContext.Current.CancellationToken;
        Assert.Equal(expected: "first", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);

        // Moved.
        File.Delete(path: Path.Combine(path1: first, path2: "az.cmd"));
        File.WriteAllText(path: Path.Combine(path1: second, path2: "az.cmd"), contents: "@echo {\"accessToken\": \"second\", \"expires_on\": 1792564306}\r\n");
        provider.Invalidate();
        var error = await Assert.ThrowsAsync<AuthException>(testCode: () => provider.TokenAsync(cancellationToken: cancellationToken));
        Assert.Equal(expected: AuthError.Failed(message: "Couldn't run the Azure CLI."), actual: error.Error);
        Assert.Null(@object: provider.Program);

        Assert.Equal(expected: "second", actual: (await provider.TokenAsync(cancellationToken: cancellationToken)).Value);
        Assert.Equal(expected: Path.Combine(path1: second, path2: "az.cmd"), actual: provider.Program);
    }
}
