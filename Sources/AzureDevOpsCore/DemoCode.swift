import Foundation

/// Made-up code for the demo's comment threads on lines of files: each file before its pull request and after each push
/// to it, so that the panel shows the code a thread is on without a network. The demo's other pull requests have an
/// iteration that changed none of it.
struct DemoCode: CodeSource {
    /// A file a pull request changed: its text before the pull request, and after each of its iterations, nil where
    /// there's no file. A text with a NUL byte isn't text, as a picture.
    struct File {
        var path: String
        /// Where it was before the pull request, when the pull request renamed it.
        var originalPath: String? = nil
        var base: String?
        /// From the first iteration on.
        var versions: [String?]

        /// After `iteration`, or before the pull request for 0.
        func text(_ iteration: Int) -> String? {
            iteration == 0 ? base : versions[min(iteration, versions.count) - 1]
        }

        /// Whether it's at `path` at `iteration`: before the pull request, at its original path.
        func isAt(_ path: String, _ iteration: Int) -> Bool {
            GitPath(iteration == 0 ? originalPath ?? self.path : self.path) == GitPath(path)
        }
    }

    struct Changes {
        /// When each iteration was pushed, from the first on: how long ago, or nil for when the pull request was created.
        var pushedAgo: [TimeInterval?]
        var files: [File]
    }

    /// By pull request number.
    static let pullRequests: [Int: Changes] = [
        // Sam asks to cap the backoff that the second push added, on line 88 of the payments client. Before it, Priya
        // asked for its number of attempts to come from configuration (line 41), and Sam for another name for the retry
        // policy (its line 12).
        4102: Changes(pushedAgo: [nil, 3 * 3_600], files: [
            File(path: "/src/PaymentsClient.cs", base: paymentsClientBase, versions: [paymentsClientRetries, paymentsClientBackoff]),
            File(path: "/tests/PaymentsClientTests.cs", base: nil, versions: [nil, paymentsClientTests]),
            File(path: "/src/RetryPolicy.cs", base: nil, versions: [retryPolicy, retryPolicy]),
            File(path: "/src/RetryOptions.cs", base: nil, versions: [nil, retryOptions]),
        ] + paymentsRetryFiles),
        // Maria pointed out that the cutoff is the warehouse's, on line 27 of the delivery estimate, which the second push
        // fixed.
        4088: Changes(pushedAgo: [nil, 28 * 3_600], files: [
            File(path: "/src/Delivery/DeliveryEstimate.cs", base: nil, versions: [deliveryEstimateServerTime, deliveryEstimate]),
        ]),
        // Priya asks for a test of the rounding on line 42, a few seconds after the demo starts. Before it, Chen asked how
        // a negative total rounds, on line 118 of the coupon service, which rounds yen to whole yen since the second push.
        4091: Changes(pushedAgo: [nil, 4.5 * 3_600], files: [
            File(path: "/src/Coupons/Rounding.cs", base: roundingBase, versions: [roundingFixed, roundingFixed]),
            File(path: "/tests/Coupons/RoundingTests.cs", base: nil, versions: [nil, roundingTests]),
            File(path: "/src/Coupons/CouponService.cs", base: couponServiceBase, versions: [couponServiceRounded, couponService]),
        ]),
        // Jordan's upgrade of the build agents to .NET 9, waiting for your review (DemoChangedFiles.swift).
        4110: Changes(pushedAgo: [nil], files: buildAgentsUpgradeFiles),
    ]

    /// Each version of each file, by its object ID, found once rather than for each read.
    private static let byObjectId: [String: String] = {
        var texts: [String: String] = [:]
        for made in pullRequests.values {
            for file in made.files {
                for text in ([file.base] + file.versions).compactMap({ $0 }) { texts[objectId(text)] = text }
            }
        }
        return texts
    }()

    func iterations(of pullRequest: PullRequest) async throws -> [PRIteration] {
        let number = pullRequest.key.number
        let pushedAgo = Self.pullRequests[number]?.pushedAgo ?? [nil]
        return pushedAgo.indices.map { index in
            PRIteration(
                id: index + 1, sourceCommit: Self.commit(number, index + 1, of: pushedAgo.count),
                targetCommit: pullRequest.targetCommit, commonCommit: Self.base(number),
                createdAt: pushedAgo[index].map { Date().addingTimeInterval(-$0) } ?? pullRequest.createdAt
            )
        }
    }

    func changes(of pullRequest: PullRequest, iteration: Int, comparedTo: Int) async throws -> FileChanges {
        guard let made = Self.pullRequests[pullRequest.key.number] else { return FileChanges(files: []) }
        return FileChanges(files: made.files.enumerated().compactMap { index, file in
            let old = file.text(comparedTo)
            let new = file.text(iteration)
            // Renamed since the base: moved, and edited too when its text changed.
            let renamed = comparedTo == 0 && file.originalPath != nil && old != nil && new != nil
            guard old != new || renamed else { return nil }
            var kind: FileChange.Kind = old == nil ? .add : new == nil ? .delete : .edit
            if renamed { kind = old == new ? .rename : [.rename, .edit] }
            return FileChange(
                path: file.path, originalPath: renamed ? file.originalPath : nil, kind: kind, objectId: new.map(Self.objectId),
                originalObjectId: old.map(Self.objectId), changeTrackingId: index + 1
            )
        })
    }

    func file(of pullRequest: PullRequest, objectId: String, limit: Int) async throws -> FileText {
        guard let text = Self.byObjectId[objectId] else { throw ADOError.notFound }
        return Self.read(text)
    }

    func file(of pullRequest: PullRequest, path: String, commit: String, limit: Int) async throws -> FileText {
        let number = pullRequest.key.number
        guard let made = Self.pullRequests[number] else { throw ADOError.notFound }
        let iteration = commit == Self.base(number)
            ? 0 : made.pushedAgo.indices.first { Self.commit(number, $0 + 1, of: made.pushedAgo.count) == commit }.map { $0 + 1 }
        guard let iteration, let text = made.files.first(where: { $0.isAt(path, iteration) })?.text(iteration) else {
            throw ADOError.notFound
        }
        return Self.read(text)
    }

    /// A file's text, or a picture's bytes, which aren't text.
    private static func read(_ text: String) -> FileText {
        text.contains("\0") ? .binary : .text(text)
    }

    /// An iteration's head: the pull request's own for the latest, as the demo's pull requests have it.
    static func commit(_ number: Int, _ iteration: Int, of count: Int) -> String {
        iteration == count ? "c\(number)" : "c\(number)-\(iteration)"
    }

    /// Where the pull request's branch left its target.
    static func base(_ number: Int) -> String {
        "b\(number)"
    }

    /// The same for the same text, as Git's are: 64-bit FNV-1a, in hexadecimal.
    static func objectId(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    // MARK: The files

    /// The payments client before the pull request: no retries.
    static let paymentsClientBase = """
    using System;
    using System.Net;
    using System.Net.Http;
    using System.Net.Http.Json;
    using System.Threading;
    using System.Threading.Tasks;
    using Microsoft.Extensions.Logging;

    namespace Storefront.Payments;

    /// <summary>
    /// Talks to the payment provider: authorizes, captures and refunds payments.
    /// </summary>
    public sealed class PaymentsClient
    {
        private readonly HttpClient http;
        private readonly ILogger<PaymentsClient> logger;

        public PaymentsClient(HttpClient http, ILogger<PaymentsClient> logger)
        {
            this.http = http;
            this.logger = logger;
        }

        public Task<PaymentResult> AuthorizeAsync(PaymentRequest request, CancellationToken cancellation) =>
            SendAsync(HttpMethod.Post, "payments/authorize", request, cancellation);

        public Task<PaymentResult> CaptureAsync(string paymentId, decimal amount, CancellationToken cancellation) =>
            SendAsync(HttpMethod.Post, $"payments/{paymentId}/capture", new { amount }, cancellation);

        public Task<PaymentResult> RefundAsync(string paymentId, decimal amount, CancellationToken cancellation) =>
            SendAsync(HttpMethod.Post, $"payments/{paymentId}/refund", new { amount }, cancellation);

        public async Task<PaymentStatus> StatusAsync(string paymentId, CancellationToken cancellation)
        {
            using var response = await http.GetAsync($"payments/{paymentId}", cancellation);
            response.EnsureSuccessStatusCode();
            var status = await response.Content.ReadFromJsonAsync<PaymentStatus>(cancellationToken: cancellation);
            return status ?? throw new PaymentException("The payment provider sent an empty status.");
        }

        private async Task<PaymentResult> SendAsync(HttpMethod method, string path, object body, CancellationToken cancellation)
        {
            using var message = new HttpRequestMessage(method, path) { Content = JsonContent.Create(body) };
            using var response = await http.SendAsync(message, cancellation);
            if (!response.IsSuccessStatusCode)
            {
                throw new PaymentException($"The payment provider answered {(int)response.StatusCode}.");
            }

            return await ReadResultAsync(response, cancellation);
        }

        private static async Task<PaymentResult> ReadResultAsync(HttpResponseMessage response, CancellationToken cancellation)
        {
            var result = await response.Content.ReadFromJsonAsync<PaymentResult>(cancellationToken: cancellation);
            return result ?? throw new PaymentException("The payment provider sent an empty result.");
        }

    }

    """

    /// After the first push: tries three times, 200 ms apart, again the failures the retry policy says may pass.
    static let paymentsClientRetries = """
    using System;
    using System.Net.Http;
    using System.Net.Http.Json;
    using System.Security.Cryptography;
    using System.Text;
    using System.Text.Json;
    using System.Threading;
    using System.Threading.Tasks;
    using Microsoft.Extensions.Logging;

    namespace Storefront.Payments;

    /// <summary>
    /// Talks to the payment provider: authorizes, captures and refunds payments.
    /// </summary>
    public sealed class PaymentsClient
    {
        /// <summary>How long to wait before trying again.</summary>
        private static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(200);

        /// <summary>How many times to try a request, the first time included.</summary>
        private const int MaxAttempts = 3;

        private readonly HttpClient http;
        private readonly ILogger<PaymentsClient> logger;

        public PaymentsClient(HttpClient http, ILogger<PaymentsClient> logger)
        {
            this.http = http;
            this.logger = logger;
        }

        public Task<PaymentResult> AuthorizeAsync(PaymentRequest request, CancellationToken cancellation) =>
            SendAsync(HttpMethod.Post, "payments/authorize", request, cancellation);

        public Task<PaymentResult> CaptureAsync(string paymentId, decimal amount, CancellationToken cancellation) =>
            SendAsync(HttpMethod.Post, $"payments/{paymentId}/capture", new { amount }, cancellation);

        public Task<PaymentResult> RefundAsync(string paymentId, decimal amount, CancellationToken cancellation) =>
            SendAsync(HttpMethod.Post, $"payments/{paymentId}/refund", new { amount }, cancellation);

        public async Task<PaymentStatus> StatusAsync(string paymentId, CancellationToken cancellation)
        {
            using var response = await http.GetAsync($"payments/{paymentId}", cancellation);
            response.EnsureSuccessStatusCode();
            var status = await response.Content.ReadFromJsonAsync<PaymentStatus>(cancellationToken: cancellation);
            return status ?? throw new PaymentException("The payment provider sent an empty status.");
        }

        /// <summary>
        /// Sends a request, and sends it again while it fails in a way that may pass.
        /// </summary>
        private async Task<PaymentResult> SendAsync(HttpMethod method, string path, object body, CancellationToken cancellation)
        {
            for (var attempt = 1; ; attempt++)
            {
                using var message = new HttpRequestMessage(method, path) { Content = JsonContent.Create(body) };
                // The same key each time, so that the provider charges a retried payment once.
                message.Headers.Add("Idempotency-Key", IdempotencyKey(method, path, body));

                using var response = await http.SendAsync(message, cancellation);
                if (response.IsSuccessStatusCode)
                {
                    return await ReadResultAsync(response, cancellation);
                }

                if (!RetryPolicy.IsTransient(response.StatusCode) || attempt == MaxAttempts)
                {
                    throw new PaymentException($"The payment provider answered {(int)response.StatusCode}.");
                }

                logger.LogWarning("Payment request failed with {Status}; retrying (attempt {Attempt} of {MaxAttempts}).",
                    (int)response.StatusCode, attempt, MaxAttempts);
                await Task.Delay(RetryDelay, cancellation);
            }
        }

        private static async Task<PaymentResult> ReadResultAsync(HttpResponseMessage response, CancellationToken cancellation)
        {
            var result = await response.Content.ReadFromJsonAsync<PaymentResult>(cancellationToken: cancellation);
            return result ?? throw new PaymentException("The payment provider sent an empty result.");
        }

        /// <summary>
        /// The same key for the same request, so that the provider charges a retried payment once.
        /// </summary>
        private static string IdempotencyKey(HttpMethod method, string path, object body) =>
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{method} {path} {JsonSerializer.Serialize(body)}")));
    }

    """

    /// After the second: as many times as configured, on line 41, and from 200 ms apart, doubling on line 88.
    static let paymentsClientBackoff = """
    using System;
    using System.Net.Http;
    using System.Net.Http.Json;
    using System.Security.Cryptography;
    using System.Text;
    using System.Text.Json;
    using System.Threading;
    using System.Threading.Tasks;
    using Microsoft.Extensions.Logging;
    using Microsoft.Extensions.Options;

    namespace Storefront.Payments;

    /// <summary>
    /// Talks to the payment provider: authorizes, captures and refunds payments.
    /// </summary>
    public sealed class PaymentsClient
    {
        /// <summary>How long to wait before the first retry.</summary>
        private static readonly TimeSpan FirstDelay = TimeSpan.FromMilliseconds(200);

        private readonly HttpClient http;
        private readonly ILogger<PaymentsClient> logger;

        /// <summary>How many times to try a request, the first time included.</summary>
        private readonly int maxAttempts;

        /// <summary>
        /// A client for the payment provider that <paramref name="http"/> is set up for.
        /// </summary>
        /// <param name="http">Sends the requests, with the provider's address and credentials.</param>
        /// <param name="retryOptions">How many times a request that fails for a moment is tried.</param>
        /// <param name="logger">Logs the requests that are tried again.</param>
        public PaymentsClient(HttpClient http, IOptions<RetryOptions> retryOptions, ILogger<PaymentsClient> logger)
        {
            ArgumentNullException.ThrowIfNull(http);
            ArgumentNullException.ThrowIfNull(retryOptions);
            this.http = http;
            this.logger = logger;
            // The Payments:Retry section of the configuration, or five attempts.
            maxAttempts = retryOptions.Value.MaxAttempts;
        }

        public Task<PaymentResult> AuthorizeAsync(PaymentRequest request, CancellationToken cancellation) =>
            SendAsync(HttpMethod.Post, "payments/authorize", request, cancellation);

        public Task<PaymentResult> CaptureAsync(string paymentId, decimal amount, CancellationToken cancellation) =>
            SendAsync(HttpMethod.Post, $"payments/{paymentId}/capture", new { amount }, cancellation);

        public Task<PaymentResult> RefundAsync(string paymentId, decimal amount, CancellationToken cancellation) =>
            SendAsync(HttpMethod.Post, $"payments/{paymentId}/refund", new { amount }, cancellation);

        public async Task<PaymentStatus> StatusAsync(string paymentId, CancellationToken cancellation)
        {
            using var response = await http.GetAsync($"payments/{paymentId}", cancellation);
            response.EnsureSuccessStatusCode();
            var status = await response.Content.ReadFromJsonAsync<PaymentStatus>(cancellationToken: cancellation);
            return status ?? throw new PaymentException("The payment provider sent an empty status.");
        }

        /// <summary>
        /// Sends a request, and sends it again while it fails in a way that may pass, waiting twice as long before each
        /// retry as before the one before it.
        /// </summary>
        private async Task<PaymentResult> SendAsync(HttpMethod method, string path, object body, CancellationToken cancellation)
        {
            var delay = FirstDelay;
            for (var attempt = 1; ; attempt++)
            {
                using var message = new HttpRequestMessage(method, path) { Content = JsonContent.Create(body) };
                // The same key each time, so that the provider charges a retried payment once.
                message.Headers.Add("Idempotency-Key", IdempotencyKey(method, path, body));

                using var response = await http.SendAsync(message, cancellation);
                if (response.IsSuccessStatusCode)
                {
                    return await ReadResultAsync(response, cancellation);
                }

                if (!RetryPolicy.IsTransient(response.StatusCode) || attempt == maxAttempts)
                {
                    throw new PaymentException($"The payment provider answered {(int)response.StatusCode}.");
                }

                logger.LogWarning("Payment request failed with {Status}; retrying in {Delay} ms (attempt {Attempt} of {MaxAttempts}).",
                    (int)response.StatusCode, delay.TotalMilliseconds, attempt, maxAttempts);
                await Task.Delay(delay, cancellation);
                delay *= 2;
            }
        }

        private static async Task<PaymentResult> ReadResultAsync(HttpResponseMessage response, CancellationToken cancellation)
        {
            var result = await response.Content.ReadFromJsonAsync<PaymentResult>(cancellationToken: cancellation);
            return result ?? throw new PaymentException("The payment provider sent an empty result.");
        }

        /// <summary>
        /// The same key for the same request, so that the provider charges a retried payment once.
        /// </summary>
        private static string IdempotencyKey(HttpMethod method, string path, object body) =>
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{method} {path} {JsonSerializer.Serialize(body)}")));
    }

    """

    /// Its tests, which the second push adds.
    static let paymentsClientTests = """
    using System.Net;
    using System.Threading;
    using System.Threading.Tasks;
    using Xunit;

    namespace Storefront.Payments.Tests;

    public class PaymentsClientTests
    {
        [Fact]
        public async Task RetriesWhileTheProviderIsBusy()
        {
            var provider = new FakeProvider(HttpStatusCode.ServiceUnavailable, HttpStatusCode.ServiceUnavailable, HttpStatusCode.OK);
            var client = provider.Client();

            var result = await client.AuthorizeAsync(FakeProvider.Request(), CancellationToken.None);

            Assert.True(result.Authorized);
            Assert.Equal(3, provider.Requests);
        }

        [Fact]
        public async Task DoesNotRetryARejectedPayment()
        {
            var provider = new FakeProvider(HttpStatusCode.PaymentRequired);
            var client = provider.Client();

            await Assert.ThrowsAsync<PaymentException>(() => client.AuthorizeAsync(FakeProvider.Request(), CancellationToken.None));
            Assert.Equal(1, provider.Requests);
        }
    }

    """

    /// The coupon rounding before the pull request: banker's rounding.
    static let roundingBase = """
    using System;

    namespace Storefront.Payments.Coupons;

    /// <summary>
    /// Rounds what coupons take off an order to amounts the payment provider accepts.
    /// </summary>
    public static class Rounding
    {
        /// <summary>The smallest amount a coupon takes off.</summary>
        public const decimal Cent = 0.01m;

        /// <summary>
        /// What a percentage coupon takes off a total.
        /// </summary>
        public static decimal PercentageDiscount(decimal total, decimal percent)
        {
            if (percent <= 0m)
            {
                return 0m;
            }

            var discount = total * Math.Min(percent, 100m) / 100m;
            return RoundToCents(discount);
        }

        /// <summary>
        /// What a coupon for a fixed amount takes off a total: never more than the total.
        /// </summary>
        public static decimal FixedDiscount(decimal total, decimal amount) =>
            RoundToCents(Math.Min(total, Math.Max(0m, amount)));

        /// <summary>
        /// Rounds to whole cents.
        /// </summary>
        public static decimal RoundToCents(decimal amount)
        {
            return Math.Round(amount, 2);
        }

        /// <summary>
        /// Splits a discount across an order's lines in proportion to their prices, so that the parts add up to it.
        /// </summary>
        public static decimal[] Split(decimal discount, decimal[] prices)
        {
            var total = 0m;
            foreach (var price in prices)
            {
                total += price;
            }

            var parts = new decimal[prices.Length];
            if (total == 0m)
            {
                return parts;
            }

            var left = discount;
            for (var i = 0; i < prices.Length - 1; i++)
            {
                parts[i] = RoundToCents(discount * prices[i] / total);
                left -= parts[i];
            }

            // What rounding left over goes to the last line, so that the parts add up to the discount.
            parts[^1] = left;
            return parts;
        }
    }

    """

    /// After it: half a cent away from zero, on line 42.
    static let roundingFixed = """
    using System;

    namespace Storefront.Payments.Coupons;

    /// <summary>
    /// Rounds what coupons take off an order to amounts the payment provider accepts.
    /// </summary>
    public static class Rounding
    {
        /// <summary>The smallest amount a coupon takes off.</summary>
        public const decimal Cent = 0.01m;

        /// <summary>
        /// What a percentage coupon takes off a total.
        /// </summary>
        public static decimal PercentageDiscount(decimal total, decimal percent)
        {
            if (percent <= 0m)
            {
                return 0m;
            }

            var discount = total * Math.Min(percent, 100m) / 100m;
            return RoundToCents(discount);
        }

        /// <summary>
        /// What a coupon for a fixed amount takes off a total: never more than the total.
        /// </summary>
        public static decimal FixedDiscount(decimal total, decimal amount) =>
            RoundToCents(Math.Min(total, Math.Max(0m, amount)));

        /// <summary>
        /// Rounds to whole cents, half a cent away from zero, as the payment provider does. Banker's rounding,
        /// .NET's default, rounded half a cent down on every other order, so the provider's total was a cent
        /// higher and it declined the payment.
        /// </summary>
        public static decimal RoundToCents(decimal amount)
        {
            // A total can be negative after a refund: away from zero rounds it as it rounds the same total
            // when it's positive.
            return Math.Round(amount, 2, MidpointRounding.AwayFromZero);
        }

        /// <summary>
        /// Splits a discount across an order's lines in proportion to their prices, so that the parts add up to it.
        /// </summary>
        public static decimal[] Split(decimal discount, decimal[] prices)
        {
            var total = 0m;
            foreach (var price in prices)
            {
                total += price;
            }

            var parts = new decimal[prices.Length];
            if (total == 0m)
            {
                return parts;
            }

            var left = discount;
            for (var i = 0; i < prices.Length - 1; i++)
            {
                parts[i] = RoundToCents(discount * prices[i] / total);
                left -= parts[i];
            }

            // What rounding left over goes to the last line, so that the parts add up to the discount.
            parts[^1] = left;
            return parts;
        }
    }

    """

    /// Its tests, which the second push adds.
    static let roundingTests = """
    using Storefront.Payments.Coupons;
    using Xunit;

    namespace Storefront.Payments.Tests.Coupons;

    public class RoundingTests
    {
        [Theory]
        [InlineData(10.125, 10.13)]
        [InlineData(10.135, 10.14)]
        [InlineData(0.005, 0.01)]
        public void RoundsHalfACentUp(decimal amount, decimal expected) =>
            Assert.Equal(expected, Rounding.RoundToCents(amount));

        [Fact]
        public void SplitsADiscountIntoPartsThatAddUpToIt()
        {
            var parts = Rounding.Split(10m, new[] { 3m, 3m, 3m });

            Assert.Equal(10m, parts[0] + parts[1] + parts[2]);
            Assert.Equal(3.33m, parts[0]);
        }
    }

    """

    /// The failures worth trying again, which the first push adds: the class Sam would rename, on line 12.
    static let retryPolicy = """
    using System.Net;

    namespace Storefront.Payments;

    /// <summary>
    /// Which failed requests to the payment provider are worth sending again.
    /// </summary>
    /// <remarks>
    /// The provider answers 429 or 503 while it's busy, and the gateway in front of it 502 or 504 when it doesn't hear
    /// back in time: those requests may pass a moment later. Others would fail the same way again.
    /// </remarks>
    public static class RetryPolicy
    {
        /// <summary>Whether a request that failed with <paramref name="status"/> may pass if it's sent again.</summary>
        public static bool IsTransient(HttpStatusCode status) => status switch
        {
            HttpStatusCode.RequestTimeout => true,
            HttpStatusCode.TooManyRequests => true,
            HttpStatusCode.BadGateway => true,
            HttpStatusCode.ServiceUnavailable => true,
            HttpStatusCode.GatewayTimeout => true,
            _ => false,
        };
    }

    """

    /// How many times to try, from configuration, which the second push adds.
    static let retryOptions = """
    namespace Storefront.Payments;

    /// <summary>
    /// How the payments client tries again a request that failed for a moment: the Payments:Retry section of the
    /// configuration.
    /// </summary>
    public sealed class RetryOptions
    {
        public const string Section = "Payments:Retry";

        /// <summary>How many times to try a request, the first time included.</summary>
        public int MaxAttempts { get; set; } = 5;
    }

    """

    /// The delivery estimate as the first push adds it: by the server's clock, on line 27.
    static let deliveryEstimateServerTime = """
    using System;
    using Storefront.Inventory;

    namespace Storefront.Delivery;

    /// <summary>
    /// When an order placed now arrives: the carrier's next delivery day after it ships, which is today before the
    /// warehouse's cutoff, and tomorrow after it.
    /// </summary>
    public sealed class DeliveryEstimate
    {
        /// <summary>Orders placed before this time of day ship the same day.</summary>
        public static readonly TimeOnly Cutoff = new(14, 0);

        private readonly TimeProvider clock;
        private readonly ICarrierCalendar carrier;

        public DeliveryEstimate(TimeProvider clock, ICarrierCalendar carrier)
        {
            this.clock = clock;
            this.carrier = carrier;
        }

        /// <summary>The day an order of items from <paramref name="warehouse"/> placed now arrives.</summary>
        public DateOnly ArrivesOn(Warehouse warehouse)
        {
            var now = clock.GetLocalNow();
            var shipsOn = DateOnly.FromDateTime(now.DateTime);
            if (TimeOnly.FromDateTime(now.DateTime) >= Cutoff)
            {
                shipsOn = shipsOn.AddDays(1);
            }

            return carrier.NextDeliveryDay(after: shipsOn);
        }
    }

    """

    /// After the second: by the warehouse's.
    static let deliveryEstimate = """
    using System;
    using Storefront.Inventory;

    namespace Storefront.Delivery;

    /// <summary>
    /// When an order placed now arrives: the carrier's next delivery day after it ships, which is today before the
    /// warehouse's cutoff, and tomorrow after it.
    /// </summary>
    public sealed class DeliveryEstimate
    {
        /// <summary>Orders placed before this time of day, at the warehouse, ship the same day.</summary>
        public static readonly TimeOnly Cutoff = new(14, 0);

        private readonly TimeProvider clock;
        private readonly ICarrierCalendar carrier;

        public DeliveryEstimate(TimeProvider clock, ICarrierCalendar carrier)
        {
            this.clock = clock;
            this.carrier = carrier;
        }

        /// <summary>The day an order of items from <paramref name="warehouse"/> placed now arrives.</summary>
        public DateOnly ArrivesOn(Warehouse warehouse)
        {
            var now = TimeZoneInfo.ConvertTime(clock.GetUtcNow(), warehouse.TimeZone);
            var shipsOn = DateOnly.FromDateTime(now.DateTime);
            if (TimeOnly.FromDateTime(now.DateTime) >= Cutoff)
            {
                shipsOn = shipsOn.AddDays(1);
            }

            return carrier.NextDeliveryDay(after: shipsOn);
        }
    }

    """

    /// The coupon service before the pull request: totals cut to the cent, on line 117.
    static let couponServiceBase = """
    using System;
    using System.Collections.Generic;
    using System.Linq;
    using System.Threading;
    using System.Threading.Tasks;
    using Microsoft.Extensions.Logging;
    using Storefront.Payments.Carts;

    namespace Storefront.Payments.Coupons;

    /// <summary>
    /// Applies coupons to carts: checks that a code may be used, and takes its discount off the cart's total.
    /// </summary>
    public sealed class CouponService
    {
        private readonly ICouponStore coupons;
        private readonly TimeProvider clock;
        private readonly ILogger<CouponService> logger;

        public CouponService(ICouponStore coupons, TimeProvider clock, ILogger<CouponService> logger)
        {
            this.coupons = coupons;
            this.clock = clock;
            this.logger = logger;
        }

        /// <summary>
        /// The cart's total with the coupon <paramref name="code"/> applied, or why it can't be.
        /// </summary>
        public async Task<CouponResult> ApplyAsync(Cart cart, string code, CancellationToken cancellation)
        {
            var coupon = await coupons.FindAsync(Normalize(code), cancellation);
            if (coupon is null)
            {
                return CouponResult.Rejected("This code doesn't exist.");
            }

            if (Validate(coupon, cart) is { } problem)
            {
                logger.LogInformation("Coupon {Code} rejected: {Problem}", coupon.Code, problem);
                return CouponResult.Rejected(problem);
            }

            var total = Apply(coupon, cart);
            logger.LogInformation("Coupon {Code} applied to cart {Cart}: {Before} to {After} {Currency}.",
                coupon.Code, cart.Id, cart.Total, total, cart.Currency);
            return CouponResult.Applied(coupon, total);
        }

        /// <summary>Codes are typed in any case, with spaces around them.</summary>
        public static string Normalize(string code) => code.Trim().ToUpperInvariant();

        /// <summary>
        /// Why <paramref name="coupon"/> can't be used on <paramref name="cart"/>, or null when it can.
        /// </summary>
        private string? Validate(Coupon coupon, Cart cart)
        {
            var today = DateOnly.FromDateTime(clock.GetUtcNow().UtcDateTime);
            if (today < coupon.ValidFrom)
            {
                return $"This code can be used from {coupon.ValidFrom:d}.";
            }

            if (today > coupon.ValidUntil)
            {
                return "This code has expired.";
            }

            if (coupon.Currency is { } currency && currency != cart.Currency)
            {
                return $"This code is for totals in {currency}.";
            }

            if (cart.Total < coupon.MinimumTotal)
            {
                return $"This code needs a total of at least {coupon.MinimumTotal} {cart.Currency}.";
            }

            if (coupon.UsesLeft == 0)
            {
                return "This code has been used as many times as it can be.";
            }

            return null;
        }

        /// <summary>
        /// The cart's items that <paramref name="coupon"/> takes money off: all of them, or those in its categories.
        /// </summary>
        private static IEnumerable<CartItem> Discounted(Coupon coupon, Cart cart) =>
            coupon.Categories.Count == 0
                ? cart.Items
                : cart.Items.Where(item => coupon.Categories.Contains(item.Category));

        /// <summary>
        /// The cart's total with the coupon's discount taken off, in the cart's currency.
        /// </summary>
        /// <remarks>
        /// The discount is split across the discounted items, in proportion to their prices, so that a refund of one
        /// item gives back what was paid for it.
        /// </remarks>
        internal static decimal Apply(Coupon coupon, Cart cart)
        {
            var prices = Discounted(coupon, cart).Select(item => item.Price * item.Quantity).ToArray();
            var subtotal = prices.Sum();
            var discount = coupon.Kind switch
            {
                CouponKind.Percentage => Rounding.PercentageDiscount(subtotal, coupon.Value),
                CouponKind.Fixed => Rounding.FixedDiscount(subtotal, coupon.Value),
                _ => throw new InvalidOperationException($"Unknown coupon kind {coupon.Kind}."),
            };

            var parts = Rounding.Split(discount, prices);
            var total = cart.Total - parts.Sum();

            // To the cent: the payment provider takes no fraction of one.
            return Math.Truncate(total * 100m) / 100m;
        }
    }

    """

    /// After the first push: rounded half away from zero.
    static let couponServiceRounded = """
    using System;
    using System.Collections.Generic;
    using System.Linq;
    using System.Threading;
    using System.Threading.Tasks;
    using Microsoft.Extensions.Logging;
    using Storefront.Payments.Carts;

    namespace Storefront.Payments.Coupons;

    /// <summary>
    /// Applies coupons to carts: checks that a code may be used, and takes its discount off the cart's total.
    /// </summary>
    public sealed class CouponService
    {
        private readonly ICouponStore coupons;
        private readonly TimeProvider clock;
        private readonly ILogger<CouponService> logger;

        public CouponService(ICouponStore coupons, TimeProvider clock, ILogger<CouponService> logger)
        {
            this.coupons = coupons;
            this.clock = clock;
            this.logger = logger;
        }

        /// <summary>
        /// The cart's total with the coupon <paramref name="code"/> applied, or why it can't be.
        /// </summary>
        public async Task<CouponResult> ApplyAsync(Cart cart, string code, CancellationToken cancellation)
        {
            var coupon = await coupons.FindAsync(Normalize(code), cancellation);
            if (coupon is null)
            {
                return CouponResult.Rejected("This code doesn't exist.");
            }

            if (Validate(coupon, cart) is { } problem)
            {
                logger.LogInformation("Coupon {Code} rejected: {Problem}", coupon.Code, problem);
                return CouponResult.Rejected(problem);
            }

            var total = Apply(coupon, cart);
            logger.LogInformation("Coupon {Code} applied to cart {Cart}: {Before} to {After} {Currency}.",
                coupon.Code, cart.Id, cart.Total, total, cart.Currency);
            return CouponResult.Applied(coupon, total);
        }

        /// <summary>Codes are typed in any case, with spaces around them.</summary>
        public static string Normalize(string code) => code.Trim().ToUpperInvariant();

        /// <summary>
        /// Why <paramref name="coupon"/> can't be used on <paramref name="cart"/>, or null when it can.
        /// </summary>
        private string? Validate(Coupon coupon, Cart cart)
        {
            var today = DateOnly.FromDateTime(clock.GetUtcNow().UtcDateTime);
            if (today < coupon.ValidFrom)
            {
                return $"This code can be used from {coupon.ValidFrom:d}.";
            }

            if (today > coupon.ValidUntil)
            {
                return "This code has expired.";
            }

            if (coupon.Currency is { } currency && currency != cart.Currency)
            {
                return $"This code is for totals in {currency}.";
            }

            if (cart.Total < coupon.MinimumTotal)
            {
                return $"This code needs a total of at least {coupon.MinimumTotal} {cart.Currency}.";
            }

            if (coupon.UsesLeft == 0)
            {
                return "This code has been used as many times as it can be.";
            }

            return null;
        }

        /// <summary>
        /// The cart's items that <paramref name="coupon"/> takes money off: all of them, or those in its categories.
        /// </summary>
        private static IEnumerable<CartItem> Discounted(Coupon coupon, Cart cart) =>
            coupon.Categories.Count == 0
                ? cart.Items
                : cart.Items.Where(item => coupon.Categories.Contains(item.Category));

        /// <summary>
        /// The cart's total with the coupon's discount taken off, in the cart's currency.
        /// </summary>
        /// <remarks>
        /// The discount is split across the discounted items, in proportion to their prices, so that a refund of one
        /// item gives back what was paid for it.
        /// </remarks>
        internal static decimal Apply(Coupon coupon, Cart cart)
        {
            var prices = Discounted(coupon, cart).Select(item => item.Price * item.Quantity).ToArray();
            var subtotal = prices.Sum();
            var discount = coupon.Kind switch
            {
                CouponKind.Percentage => Rounding.PercentageDiscount(subtotal, coupon.Value),
                CouponKind.Fixed => Rounding.FixedDiscount(subtotal, coupon.Value),
                _ => throw new InvalidOperationException($"Unknown coupon kind {coupon.Kind}."),
            };

            var parts = Rounding.Split(discount, prices);
            var total = cart.Total - parts.Sum();

            // Half away from zero, as the payment provider rounds.
            return Rounding.RoundToCents(total);
        }
    }

    """

    /// After the second: and yen to whole yen, on line 118.
    static let couponService = """
    using System;
    using System.Collections.Generic;
    using System.Linq;
    using System.Threading;
    using System.Threading.Tasks;
    using Microsoft.Extensions.Logging;
    using Storefront.Payments.Carts;

    namespace Storefront.Payments.Coupons;

    /// <summary>
    /// Applies coupons to carts: checks that a code may be used, and takes its discount off the cart's total.
    /// </summary>
    public sealed class CouponService
    {
        private readonly ICouponStore coupons;
        private readonly TimeProvider clock;
        private readonly ILogger<CouponService> logger;

        public CouponService(ICouponStore coupons, TimeProvider clock, ILogger<CouponService> logger)
        {
            this.coupons = coupons;
            this.clock = clock;
            this.logger = logger;
        }

        /// <summary>
        /// The cart's total with the coupon <paramref name="code"/> applied, or why it can't be.
        /// </summary>
        public async Task<CouponResult> ApplyAsync(Cart cart, string code, CancellationToken cancellation)
        {
            var coupon = await coupons.FindAsync(Normalize(code), cancellation);
            if (coupon is null)
            {
                return CouponResult.Rejected("This code doesn't exist.");
            }

            if (Validate(coupon, cart) is { } problem)
            {
                logger.LogInformation("Coupon {Code} rejected: {Problem}", coupon.Code, problem);
                return CouponResult.Rejected(problem);
            }

            var total = Apply(coupon, cart);
            logger.LogInformation("Coupon {Code} applied to cart {Cart}: {Before} to {After} {Currency}.",
                coupon.Code, cart.Id, cart.Total, total, cart.Currency);
            return CouponResult.Applied(coupon, total);
        }

        /// <summary>Codes are typed in any case, with spaces around them.</summary>
        public static string Normalize(string code) => code.Trim().ToUpperInvariant();

        /// <summary>
        /// Why <paramref name="coupon"/> can't be used on <paramref name="cart"/>, or null when it can.
        /// </summary>
        private string? Validate(Coupon coupon, Cart cart)
        {
            var today = DateOnly.FromDateTime(clock.GetUtcNow().UtcDateTime);
            if (today < coupon.ValidFrom)
            {
                return $"This code can be used from {coupon.ValidFrom:d}.";
            }

            if (today > coupon.ValidUntil)
            {
                return "This code has expired.";
            }

            if (coupon.Currency is { } currency && currency != cart.Currency)
            {
                return $"This code is for totals in {currency}.";
            }

            if (cart.Total < coupon.MinimumTotal)
            {
                return $"This code needs a total of at least {coupon.MinimumTotal} {cart.Currency}.";
            }

            if (coupon.UsesLeft == 0)
            {
                return "This code has been used as many times as it can be.";
            }

            return null;
        }

        /// <summary>
        /// The cart's items that <paramref name="coupon"/> takes money off: all of them, or those in its categories.
        /// </summary>
        private static IEnumerable<CartItem> Discounted(Coupon coupon, Cart cart) =>
            coupon.Categories.Count == 0
                ? cart.Items
                : cart.Items.Where(item => coupon.Categories.Contains(item.Category));

        /// <summary>
        /// The cart's total with the coupon's discount taken off, in the cart's currency.
        /// </summary>
        /// <remarks>
        /// The discount is split across the discounted items, in proportion to their prices, so that a refund of one
        /// item gives back what was paid for it.
        /// </remarks>
        internal static decimal Apply(Coupon coupon, Cart cart)
        {
            var prices = Discounted(coupon, cart).Select(item => item.Price * item.Quantity).ToArray();
            var subtotal = prices.Sum();
            var discount = coupon.Kind switch
            {
                CouponKind.Percentage => Rounding.PercentageDiscount(subtotal, coupon.Value),
                CouponKind.Fixed => Rounding.FixedDiscount(subtotal, coupon.Value),
                _ => throw new InvalidOperationException($"Unknown coupon kind {coupon.Kind}."),
            };

            var parts = Rounding.Split(discount, prices);
            var total = cart.Total - parts.Sum();

            // Half away from zero, as the payment provider rounds: to the cent, or to the whole yen, which has no
            // smaller unit.
            return cart.Currency == "JPY" ? Math.Round(total, MidpointRounding.AwayFromZero) : Rounding.RoundToCents(total);
        }
    }

    """
}
