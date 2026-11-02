import Foundation

/// Made-up code for the demo's comment threads on lines of files: each file before its pull request and after each push
/// to it, so that the panel shows the code a thread is on without a network. The demo's other pull requests have an
/// iteration that changed none of it.
struct DemoCode: CodeSource {
    /// A file a pull request changed: its text before the pull request, and after each of its iterations, nil where
    /// there's no file.
    struct File {
        var path: String
        var base: String?
        /// From the first iteration on.
        var versions: [String?]

        /// After `iteration`, or before the pull request for 0.
        func text(_ iteration: Int) -> String? {
            iteration == 0 ? base : versions[min(iteration, versions.count) - 1]
        }
    }

    struct Changes {
        /// When each iteration was pushed, from the first on: how long ago, or nil for when the pull request was created.
        var pushedAgo: [TimeInterval?]
        var files: [File]
    }

    /// By pull request number.
    static let pullRequests: [Int: Changes] = [
        // Sam asks to cap the backoff that the second push added, on line 88 of the payments client.
        4102: Changes(pushedAgo: [nil, 3 * 3_600], files: [
            File(path: "/src/PaymentsClient.cs", base: paymentsClientBase, versions: [paymentsClientRetries, paymentsClientBackoff]),
            File(path: "/tests/PaymentsClientTests.cs", base: nil, versions: [nil, paymentsClientTests]),
        ]),
        // Priya asks for a test of the rounding on line 42, a few seconds after the demo starts.
        4091: Changes(pushedAgo: [nil, 4.5 * 3_600], files: [
            File(path: "/src/Coupons/Rounding.cs", base: roundingBase, versions: [roundingFixed, roundingFixed]),
            File(path: "/tests/Coupons/RoundingTests.cs", base: nil, versions: [nil, roundingTests]),
        ]),
    ]

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
            guard old != new else { return nil }
            let kind: FileChange.Kind = old == nil ? .add : new == nil ? .delete : .edit
            return FileChange(
                path: file.path, kind: kind, objectId: new.map(Self.objectId), originalObjectId: old.map(Self.objectId),
                changeTrackingId: index + 1
            )
        })
    }

    func file(of pullRequest: PullRequest, objectId: String, limit: Int) async throws -> FileText {
        for made in Self.pullRequests.values {
            for file in made.files {
                if let text = ([file.base] + file.versions).compactMap({ $0 }).first(where: { Self.objectId($0) == objectId }) {
                    return .text(text)
                }
            }
        }
        throw ADOError.notFound
    }

    func file(of pullRequest: PullRequest, path: String, commit: String, limit: Int) async throws -> FileText {
        let number = pullRequest.key.number
        guard let made = Self.pullRequests[number], let file = made.files.first(where: { $0.path == path }) else {
            throw ADOError.notFound
        }
        let iteration = commit == Self.base(number)
            ? 0 : made.pushedAgo.indices.first { Self.commit(number, $0 + 1, of: made.pushedAgo.count) == commit }.map { $0 + 1 }
        guard let iteration, let text = file.text(iteration) else { throw ADOError.notFound }
        return .text(text)
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

    /// After the first push: retries a few times, 200 ms apart.
    static let paymentsClientRetries = """
    using System;
    using System.Net;
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

        /// <summary>Whether a failed request may pass if it's sent again: the provider is busy, or didn't answer.</summary>
        private static bool IsTransient(HttpStatusCode status) => status switch
        {
            HttpStatusCode.RequestTimeout => true,
            HttpStatusCode.TooManyRequests => true,
            HttpStatusCode.BadGateway => true,
            HttpStatusCode.ServiceUnavailable => true,
            HttpStatusCode.GatewayTimeout => true,
            _ => false,
        };

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

                if (!IsTransient(response.StatusCode) || attempt == MaxAttempts)
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

    /// After the second: exponential backoff, from 200 ms, doubling on line 88.
    static let paymentsClientBackoff = """
    using System;
    using System.Net;
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
        /// <summary>How long to wait before the first retry.</summary>
        private static readonly TimeSpan FirstDelay = TimeSpan.FromMilliseconds(200);

        /// <summary>How many times to try a request, the first time included.</summary>
        private const int MaxAttempts = 6;

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

        /// <summary>Whether a failed request may pass if it's sent again: the provider is busy, or didn't answer.</summary>
        private static bool IsTransient(HttpStatusCode status) => status switch
        {
            HttpStatusCode.RequestTimeout => true,
            HttpStatusCode.TooManyRequests => true,
            HttpStatusCode.BadGateway => true,
            HttpStatusCode.ServiceUnavailable => true,
            HttpStatusCode.GatewayTimeout => true,
            _ => false,
        };

        /// <summary>
        /// Sends a request, and sends it again while it fails in a way that may pass, waiting longer each time.
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

                if (!IsTransient(response.StatusCode) || attempt == MaxAttempts)
                {
                    throw new PaymentException($"The payment provider answered {(int)response.StatusCode}.");
                }

                logger.LogWarning("Payment request failed with {Status}; retrying in {Delay} ms (attempt {Attempt} of {MaxAttempts}).",
                    (int)response.StatusCode, delay.TotalMilliseconds, attempt, MaxAttempts);
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
}
