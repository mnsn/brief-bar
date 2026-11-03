import Foundation

// More of what the demo's pull request !4102 changed, for its Files to show each way a file can change: a file renamed
// and edited, one deleted, the README and the configuration edited, and a picture, which isn't text. Its comment threads
// are on the files in DemoCode.swift. And what !4110's upgrade of the build agents to .NET 9 changed, with a lock file of
// packages that changed in more places than `LineDiff` lines up exactly.

extension DemoCode {
    /// After the files its threads are on, so that theirs keep their tracking IDs.
    static let paymentsRetryFiles: [File] = [
        // The first push moved the provider's settings into a folder of their own, under a new name.
        File(path: "/src/Config/PaymentsSettings.cs", originalPath: "/src/PaymentsConfig.cs", base: paymentsConfig,
             versions: [paymentsSettings, paymentsSettings]),
        // And deleted the retry helper that nothing called anymore.
        File(path: "/src/LegacyRetry.cs", base: legacyRetry, versions: [nil, nil]),
        // The second said how retries work, with a diagram, and how to configure them.
        File(path: "/README.md", base: paymentsReadme, versions: [paymentsReadme, paymentsReadmeRetries]),
        File(path: "/docs/retry-backoff.png", base: nil, versions: [nil, retryDiagram]),
        File(path: "/appsettings.json", base: appSettings, versions: [appSettings, appSettingsRetries]),
    ]

    /// A picture: bytes that aren't text, as its NUL bytes tell.
    static let retryDiagram = "\u{89}PNG\r\n\u{1A}\n\0\0\0\rIHDR\0\0\u{2}\u{80}\0\0\u{1}\u{E0}\u{8}\u{6}\0\0\0"

    /// The provider's settings before the pull request.
    static let paymentsConfig = """
    namespace Storefront.Payments;

    /// <summary>
    /// Where the payment provider is, and how to sign in to it: the Payments section of the configuration.
    /// </summary>
    public sealed class PaymentsConfig
    {
        public const string Section = "Payments";

        public Uri BaseAddress { get; set; } = new("https://payments.example.com/");

        public string ApiKey { get; set; } = "";
    }

    """

    /// The same settings, renamed with the pull request's other settings, and with a timeout.
    static let paymentsSettings = """
    namespace Storefront.Payments.Config;

    /// <summary>
    /// Where the payment provider is, and how to sign in to it: the Payments section of the configuration.
    /// </summary>
    public sealed class PaymentsSettings
    {
        public const string Section = "Payments";

        public Uri BaseAddress { get; set; } = new("https://payments.example.com/");

        public string ApiKey { get; set; } = "";

        /// <summary>How long to wait for each answer from the provider.</summary>
        public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(10);
    }

    """

    /// The retry helper the payments client stopped using.
    static let legacyRetry = """
    using System;
    using System.Threading.Tasks;

    namespace Storefront.Payments;

    /// <summary>
    /// Tries an action a few times. Nothing calls it since the payments client retries by itself.
    /// </summary>
    [Obsolete("The payments client retries by itself.")]
    public static class LegacyRetry
    {
        public static async Task<T> RunAsync<T>(Func<Task<T>> action, int attempts = 3)
        {
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    return await action();
                }
                catch (PaymentException) when (attempt < attempts)
                {
                    await Task.Delay(500);
                }
            }
        }
    }

    """

    static let paymentsReadme = """
    # Payments API

    The storefront's payments service: it authorizes, captures and refunds payments with the payment provider.

    ## Running it

    1. Set `Payments:ApiKey` in your user secrets.
    2. Run `dotnet run --project src/Payments.Api`.

    ## Tests

    Run `dotnet test`. The tests use a fake provider, so they need no key.

    """

    static let paymentsReadmeRetries = """
    # Payments API

    The storefront's payments service: it authorizes, captures and refunds payments with the payment provider.

    ## Running it

    1. Set `Payments:ApiKey` in your user secrets.
    2. Run `dotnet run --project src/Payments.Api`.

    ## Retries

    A request that fails in a way that may pass, such as a 503 while the provider is busy, is sent again, up to
    `Payments:Retry:MaxAttempts` times, waiting longer each time:

    ![The delay doubles after each failed attempt](docs/retry-backoff.png)

    Each request carries an `Idempotency-Key`, so that the provider charges a retried payment once.

    ## Tests

    Run `dotnet test`. The tests use a fake provider, so they need no key.

    """

    static let appSettings = """
    {
      "Logging": {
        "LogLevel": {
          "Default": "Information"
        }
      },
      "Payments": {
        "BaseAddress": "https://payments.example.com/"
      }
    }

    """

    static let appSettingsRetries = """
    {
      "Logging": {
        "LogLevel": {
          "Default": "Information"
        }
      },
      "Payments": {
        "BaseAddress": "https://payments.example.com/",
        "Retry": {
          "MaxAttempts": 5
        }
      }
    }

    """
}

// MARK: !4110, the build agents on .NET 9

extension DemoCode {
    /// The build agents' project and SDK on .NET 9, and their packages' lock file, where four in five packages moved to a
    /// version for it: more lines changed, in more places, than `LineDiff` lines up exactly.
    static let buildAgentsUpgradeFiles: [File] = [
        File(path: "/agents/BuildAgent.csproj", base: buildAgentProject("net8.0"), versions: [buildAgentProject("net9.0")]),
        File(path: "/agents/global.json", base: sdkVersion("8.0.404"), versions: [sdkVersion("9.0.100")]),
        File(path: "/agents/packages.lock.json", base: packagesLock(upgraded: false), versions: [packagesLock(upgraded: true)]),
    ]

    static func buildAgentProject(_ framework: String) -> String {
        """
        <Project Sdk="Microsoft.NET.Sdk">

          <PropertyGroup>
            <OutputType>Exe</OutputType>
            <TargetFramework>\(framework)</TargetFramework>
            <Nullable>enable</Nullable>
            <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
          </PropertyGroup>

        </Project>

        """
    }

    static func sdkVersion(_ version: String) -> String {
        """
        {
          "sdk": {
            "version": "\(version)",
            "rollForward": "latestFeature"
          }
        }

        """
    }

    /// A NuGet lock file of 520 made-up packages: on .NET 8, or after the upgrade, with four in five of them at a version
    /// for .NET 9.
    static func packagesLock(upgraded: Bool) -> String {
        let areas = [
            "Billing", "Builds", "Caching", "Configuration", "Diagnostics", "Hosting", "Http", "Identity", "Logging", "Messaging",
            "Metrics", "Pipelines", "Queues", "Retry", "Secrets", "Storage", "Telemetry", "Testing", "Tracing", "Workers",
        ]
        let parts = [
            "Abstractions", "Adapters", "Analyzers", "Bindings", "Client", "Common", "Contracts", "Core", "Extensions", "Formats",
            "Generators", "Handlers", "Hosting", "Models", "Options", "Policies", "Primitives", "Protocols", "Providers", "Runtime",
            "Sdk", "Serialization", "Server", "Streams", "Tools", "Validation",
        ]
        var lines = ["{", "  \"version\": 1,", "  \"dependencies\": {", "    \"\(upgraded ? "net9.0" : "net8.0")\": {"]
        for index in 0..<(areas.count * parts.count) {
            let name = "Contoso.\(areas[index % areas.count]).\(parts[index / areas.count])"
            let version = upgraded && index % 5 != 0 ? "9.0.\(index % 4)" : "8.\(index % 3).\(index % 7)"
            lines += [
                "      \"\(name)\": {",
                "        \"type\": \"Direct\",",
                "        \"requested\": \"[\(version), )\",",
                "        \"resolved\": \"\(version)\",",
                "        \"contentHash\": \"\(contentHash(of: name + "@" + version))\"",
                index == areas.count * parts.count - 1 ? "      }" : "      },",
            ]
        }
        return (lines + ["    }", "  }", "}", ""]).joined(separator: "\n")
    }

    /// A made-up package's hash, in base 64: the same for the same package and version.
    private static func contentHash(of package: String) -> String {
        let digits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var state = UInt64(objectId(package), radix: 16) ?? 1
        return String((0..<43).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return digits[Int(state >> 58)]
        }) + "="
    }
}
