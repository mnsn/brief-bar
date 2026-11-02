using System.Net;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace BriefBar.Core.GitHub;

/// Reads your pull requests from GitHub. It sends one request, always the same query (`PullRequestQuery`), so it can only
/// read: GitHub's GraphQL API takes queries as POST requests, and BriefBar never sends a mutation. Each request carries a
/// token from the GitHub CLI's sign-in, through the system's proxy, with no cookies and no cache, to api.github.com only:
/// it follows no redirect (`Redirects`). A rejected token is replaced once; when GitHub asks it to slow down, nothing goes
/// out until the time GitHub gave. The Mac's `GitHubClient`.
public sealed class GitHubClient : IDisposable
{
    /// How long it waits when GitHub says to slow down only in words.
    static readonly TimeSpan wordsWait = TimeSpan.FromMinutes(value: 1);

    readonly HttpClient http;
    readonly RateLimitGate gate;
    readonly TimeProvider time;

    /// - `handler`: what sends its requests, which tests stand in for; its own otherwise.
    public GitHubClient(IGitHubTokenProvider tokens, HttpMessageHandler? handler = null, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: tokens);
        Tokens = tokens;
        this.time = time ?? TimeProvider.System;
        gate = new RateLimitGate(time: this.time);
        http = new HttpClient(handler: handler ?? MakeHandler(), disposeHandler: true) { Timeout = TimeSpan.FromSeconds(value: 60) };
        http.DefaultRequestHeaders.UserAgent.Add(item: new ProductInfoHeaderValue(product: new ProductHeaderValue(name: "BriefBar")));
    }

    public static Uri Endpoint { get; } = new(uriString: "https://api.github.com/graphql");

    public IGitHubTokenProvider Tokens { get; }

    /// Who you are, the pull requests that request your review and your own, as GitHub answers `PullRequestQuery`, with
    /// the errors it answered about what it couldn't read; throws `GitHubException` when it can't read them at all.
    public async Task<PullRequestQueryResult> PullRequestsAsync(CancellationToken cancellationToken)
    {
        var (body, untilReset) = await SendAsync(body: PullRequestQuery.Body(), cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        var (data, errors) = Decode(body: body);
        if (errors.Exists(match: error => error.Type == "RATE_LIMITED"))
        {
            var wait = untilReset ?? wordsWait;
            gate.Hold(wait: wait);
            throw new GitHubException(error: GitHubError.Throttled(retryAfter: wait));
        }
        if (data is null)
        {
            throw new GitHubException(error: GitHubError.GraphQL(message: PlainText.Prefix(text: errors.FirstOrDefault()?.Message ?? "no data", length: 300)));
        }
        return new PullRequestQueryResult(Data: data, Errors: new ValueList<GraphQLError>(items: errors));
    }

    public void Dispose() => http.Dispose();

    /// How long to wait when GitHub refuses a request for its rate limits, or null when it refused it for another reason:
    /// `Retry-After` for its secondary limits, in seconds or as a date, at most an hour (`RetryAfter`); the hourly limit's
    /// reset when that's used up; or a minute when it only says so in words. 429 is always a rate limit.
    internal static TimeSpan? RateLimitWait(HttpResponseMessage response, byte[] body, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: response);
        ArgumentNullException.ThrowIfNull(argument: body);
        if (RetryAfter.Wait(value: Header(response: response, name: "Retry-After"), now: now) is { } asked)
        {
            return asked;
        }
        if (Header(response: response, name: "x-ratelimit-remaining") == "0" && ResetWait(response: response, now: now) is { } untilReset)
        {
            return untilReset;
        }
        var message = Encoding.UTF8.GetString(bytes: body).ToLowerInvariant();
        if (response.StatusCode == HttpStatusCode.TooManyRequests || message.Contains(value: "rate limit", comparisonType: StringComparison.Ordinal))
        {
            return wordsWait;
        }
        return null;
    }

    /// Until the hourly limit resets (`x-ratelimit-reset`, seconds since 1970), at least a second and at most an hour; null
    /// when GitHub doesn't say.
    internal static TimeSpan? ResetWait(HttpResponseMessage response, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: response);
        if (RetryAfter.Seconds(text: Header(response: response, name: "x-ratelimit-reset")) is not { } reset)
        {
            return null;
        }
        var seconds = Math.Clamp(value: reset - ((now - DateTimeOffset.UnixEpoch).Ticks / (double)TimeSpan.TicksPerSecond), min: 1, max: RetryAfter.Longest.TotalSeconds);
        return TimeSpan.FromSeconds(value: seconds);
    }

    /// The only way requests are made: the query, with a token, tried again once with a fresh token if GitHub rejects it.
    /// Returns what GitHub answered, and how long until its hourly limit resets, when it says.
    internal async Task<(byte[] Body, TimeSpan? UntilReset)> SendAsync(byte[] body, CancellationToken cancellationToken)
    {
        if (gate.RemainingWait() is { } wait)
        {
            throw new GitHubException(error: GitHubError.Throttled(retryAfter: wait));
        }
        var token = await AccessTokenAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            using var request = Request(body: body, token: token.Value);
            using var response = await SendAsync(request: request, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            var answer = await response.Content.ReadAsByteArrayAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            var now = time.GetUtcNow();
            var status = (int)response.StatusCode;
            switch (status)
            {
                case >= 200 and < 300:
                    var untilReset = ResetWait(response: response, now: now);
                    // Out of requests for this hour: wait for the reset rather than be refused.
                    if (Header(response: response, name: "x-ratelimit-remaining") == "0" && untilReset is { } hourly)
                    {
                        gate.Hold(wait: hourly);
                    }
                    return (answer, untilReset);
                case 401:
                    if (attempt == 0)
                    {
                        Tokens.Invalidate();
                        token = await AccessTokenAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                        continue;
                    }
                    throw new GitHubException(error: GitHubError.Unauthorized);
                case 403 or 429:
                    if (RateLimitWait(response: response, body: answer, now: now) is { } limited)
                    {
                        gate.Hold(wait: limited);
                        throw new GitHubException(error: GitHubError.Throttled(retryAfter: limited));
                    }
                    throw new GitHubException(error: GitHubError.Forbidden);
                case >= 300 and < 400 when Redirects.OtherHost(location: response.Headers.Location, requested: Endpoint) is { } host:
                    throw new GitHubException(error: GitHubError.Network(message: "GitHub redirected BriefBar to another host, " + host + ", which it doesn't connect to."));
                default:
                    // A redirect that stays on api.github.com too: GitHub answers the query where it's sent.
                    throw new GitHubException(error: GitHubError.Http(status: status));
            }
        }
        throw new GitHubException(error: GitHubError.Unauthorized);
    }

    /// No cookies or credentials kept, no redirect followed, and connections that give up after half a minute.
    internal static SocketsHttpHandler MakeHandler() => new()
    {
        UseCookies = false,
        Credentials = null,
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(value: 30),
        AutomaticDecompression = DecompressionMethods.All,
    };

    static HttpRequestMessage Request(byte[] body, string token)
    {
        var request = new HttpRequestMessage(method: HttpMethod.Post, requestUri: Endpoint) { Content = new ByteArrayContent(content: body) };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue(mediaType: "application/json");
        request.Headers.Authorization = new AuthenticationHeaderValue(scheme: "bearer", parameter: token);
        request.Headers.Accept.Add(item: new MediaTypeWithQualityHeaderValue(mediaType: "application/json"));
        return request;
    }

    /// What GitHub answered: what it could read, and the errors it answered with; throws `GitHubException` for an answer
    /// that isn't GraphQL's, or whose data lacks what BriefBar reads.
    static (PullRequestQueryData? Data, List<GraphQLError> Errors) Decode(byte[] body)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8Json: body);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new GitHubException(error: GitHubError.Decoding(message: "not a GraphQL answer"));
            }
            var errors = new List<GraphQLError>();
            if (LenientJson.Member(element: root, name: "errors") is { } list)
            {
                if (list.ValueKind != JsonValueKind.Array)
                {
                    throw new GitHubException(error: GitHubError.Decoding(message: "errors that aren't a list"));
                }
                foreach (var item in list.EnumerateArray())
                {
                    errors.Add(item: GraphQLError.Read(element: item) ?? throw new GitHubException(error: GitHubError.Decoding(message: "an error without a message")));
                }
            }
            PullRequestQueryData? data = LenientJson.Member(element: root, name: "data") switch
            {
                null => null,
                { ValueKind: JsonValueKind.Object } payload => PullRequestQueryData.Read(element: payload),
                _ => throw new GitHubException(error: GitHubError.Decoding(message: "data that isn't an object")),
            };
            return (data, errors);
        }
        catch (JsonException error)
        {
            throw new GitHubException(error: GitHubError.Decoding(message: "not JSON"), innerException: error);
        }
    }

    /// The first value of the header `name`, as GitHub sent it.
    static string? Header(HttpResponseMessage response, string name) =>
        response.Headers.NonValidated.TryGetValues(headerName: name, values: out var values) ? values.FirstOrDefault() : null;

    /// Sends `request`, saying what kept it from GitHub as a `GitHubError`. Stopping, as BriefBar quits or GitHub is turned
    /// off, isn't one.
    async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        try
        {
            return await http.SendAsync(request: request, completionOption: HttpCompletionOption.ResponseContentRead, cancellationToken: cancellationToken)
                .ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (TaskCanceledException error) when (!cancellationToken.IsCancellationRequested)
        {
            throw new GitHubException(error: GitHubError.Network(message: "GitHub didn't answer in time."), innerException: error);
        }
        catch (HttpRequestException error)
        {
            throw new GitHubException(error: Failure(error: error), innerException: error);
        }
    }

    /// Offline when Windows has no network; otherwise, what kept the request from GitHub.
    static GitHubError Failure(HttpRequestException error)
    {
        if (!NetworkInterface.GetIsNetworkAvailable()
            || error.InnerException is SocketException { SocketErrorCode: SocketError.NetworkDown or SocketError.NetworkUnreachable })
        {
            return GitHubError.Offline;
        }
        return error.HttpRequestError switch
        {
            HttpRequestError.NameResolutionError => GitHubError.Network(message: "Can't reach GitHub."),
            HttpRequestError.ProxyTunnelError => GitHubError.Network(message: "The proxy didn't let BriefBar reach GitHub."),
            HttpRequestError.SecureConnectionError => GitHubError.Network(message: "Couldn't connect to GitHub securely."),
            _ => GitHubError.Network(message: "Couldn't connect to GitHub."),
        };
    }

    async Task<GitHubToken> AccessTokenAsync(CancellationToken cancellationToken)
    {
        try
        {
            return await Tokens.TokenAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (GitHubAuthException error)
        {
            throw new GitHubException(error: GitHubError.FromAuth(error: error.Error), innerException: error);
        }
    }
}
