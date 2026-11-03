import Foundation

// More of what the demo's pull request !4102 changed, for its Files to show each way a file can change: a file renamed
// and edited, one deleted, the README and the configuration edited, and a picture, which isn't text. Its comment threads
// are on the files in DemoCode.swift.

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
