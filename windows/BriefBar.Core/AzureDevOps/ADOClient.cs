using System.Net;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// Reads from Azure DevOps. It only ever sends GET requests, each with a bearer token from the Azure CLI's sign-in:
/// BriefBar never changes anything there. No cookies and no cache: every request carries its own token, through the
/// system's proxy. A rejected token is replaced once; `Retry-After` holds every request back until then. The Mac's
/// `ADOClient`.
public sealed class ADOClient : IDisposable
{
    readonly HttpClient http;
    readonly RateLimitGate gate;
    readonly TimeProvider time;

    /// - `handler`: what sends its requests, which tests stand in for; its own otherwise.
    public ADOClient(IAccessTokenProvider tokens, HttpMessageHandler? handler = null, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: tokens);
        Tokens = tokens;
        this.time = time ?? TimeProvider.System;
        gate = new RateLimitGate(time: this.time);
        http = new HttpClient(handler: handler ?? MakeHandler(), disposeHandler: true) { Timeout = TimeSpan.FromSeconds(value: 60) };
        http.DefaultRequestHeaders.UserAgent.Add(item: new ProductInfoHeaderValue(product: new ProductHeaderValue(name: "BriefBar")));
    }

    public IAccessTokenProvider Tokens { get; }

    /// Reads `url`, and what it answers with `read`; throws `ADOException` when it can't, or can't read what came.
    public async Task<T> GetAsync<T>(Uri url, Func<JsonElement, T?> read, CancellationToken cancellationToken)
        where T : class
    {
        ArgumentNullException.ThrowIfNull(argument: read);
        var data = await DataAsync(url: url, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        try
        {
            using var document = JsonDocument.Parse(utf8Json: data);
            return read(arg: document.RootElement) ?? throw new ADOException(error: ADOError.Decoding(message: "not what BriefBar reads"));
        }
        catch (JsonException error)
        {
            throw new ADOException(error: ADOError.Decoding(message: "not JSON"), innerException: error);
        }
    }

    /// A list, without the elements that can't be read.
    public Task<ADOList<T>> ListAsync<T>(Uri url, Func<JsonElement, T?> read, CancellationToken cancellationToken)
        where T : class =>
        GetAsync(url: url, read: element => ADOList<T>.Read(element: element, read: read), cancellationToken: cancellationToken);

    public void Dispose() => http.Dispose();

    /// The only way requests are made: GET, with a bearer token, tried again once with a new token if Azure DevOps rejects
    /// it, or answers with its sign-in page.
    internal async Task<byte[]> DataAsync(Uri url, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(argument: url);
        if (gate.RemainingWait() is { } wait)
        {
            throw new ADOException(error: ADOError.Throttled(retryAfter: wait));
        }
        var token = await AccessTokenAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            using var request = Request(url: url, token: token.Value);
            using var response = await SendAsync(request: request, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            if (RetryAfter(response: response) is { } retryAfter)
            {
                gate.Hold(wait: retryAfter);
            }
            var status = (int)response.StatusCode;
            switch (status)
            {
                case 204:
                    // Nothing there, such as the timeline of a run that has none yet: not a sign-in problem.
                    throw new ADOException(error: ADOError.NotFound);
                case >= 200 and < 300 when status != 203 && IsJson(response: response):
                    return await response.Content.ReadAsByteArrayAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                case (>= 200 and < 300) or 401:
                    // 203 with a sign-in page is how Azure DevOps answers a request it didn't authenticate.
                    if (attempt == 0)
                    {
                        Tokens.Invalidate();
                        token = await AccessTokenAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                        continue;
                    }
                    throw new ADOException(error: ADOError.Unauthorized);
                case 403:
                    throw new ADOException(error: ADOError.Forbidden);
                case 404:
                    throw new ADOException(error: ADOError.NotFound);
                case 429 or 503:
                    throw new ADOException(error: ADOError.Throttled(retryAfter: RetryAfter(response: response) ?? TimeSpan.FromSeconds(value: 60)));
                default:
                    throw new ADOException(error: ADOError.Http(status: status));
            }
        }
        throw new ADOException(error: ADOError.Unauthorized);
    }

    /// No cookies or credentials kept, and connections that give up after half a minute.
    static SocketsHttpHandler MakeHandler() => new()
    {
        UseCookies = false,
        Credentials = null,
        ConnectTimeout = TimeSpan.FromSeconds(value: 30),
        AutomaticDecompression = DecompressionMethods.All,
    };

    static HttpRequestMessage Request(Uri url, string token)
    {
        var request = new HttpRequestMessage(method: HttpMethod.Get, requestUri: url);
        request.Headers.Authorization = new AuthenticationHeaderValue(scheme: "Bearer", parameter: token);
        request.Headers.Accept.Add(item: new MediaTypeWithQualityHeaderValue(mediaType: "application/json"));
        // Answer a request it didn't authenticate with 401, rather than a redirect to its sign-in page.
        request.Headers.Add(name: "X-TFS-FedAuthRedirect", value: "Suppress");
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        return request;
    }

    static bool IsJson(HttpResponseMessage response) =>
        response.Content.Headers.ContentType?.MediaType?.Contains(value: "json", comparisonType: StringComparison.OrdinalIgnoreCase) == true;

    /// How long `Retry-After` asks to wait, at most an hour; null without one.
    static TimeSpan? RetryAfter(HttpResponseMessage response)
    {
        var wait = response.Headers.RetryAfter switch
        {
            { Delta: { } delta } => delta,
            { Date: { } date } => date - DateTimeOffset.UtcNow,
            _ => (TimeSpan?)null,
        };
        if (wait is not { } positive || positive <= TimeSpan.Zero)
        {
            return null;
        }
        return positive > TimeSpan.FromHours(value: 1) ? TimeSpan.FromHours(value: 1) : positive;
    }

    /// Sends `request`, saying what kept it from Azure DevOps as an `ADOError`. Stopping, as BriefBar quits or Azure DevOps
    /// is turned off, isn't one.
    async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        try
        {
            return await http.SendAsync(request: request, completionOption: HttpCompletionOption.ResponseContentRead, cancellationToken: cancellationToken)
                .ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (TaskCanceledException error) when (!cancellationToken.IsCancellationRequested)
        {
            throw new ADOException(error: ADOError.Network(message: "Azure DevOps didn't answer in time."), innerException: error);
        }
        catch (HttpRequestException error)
        {
            throw new ADOException(error: Failure(error: error), innerException: error);
        }
    }

    /// Offline when Windows has no network; otherwise, what kept the request from Azure DevOps.
    static ADOError Failure(HttpRequestException error)
    {
        if (!NetworkInterface.GetIsNetworkAvailable()
            || error.InnerException is SocketException { SocketErrorCode: SocketError.NetworkDown or SocketError.NetworkUnreachable })
        {
            return ADOError.Offline;
        }
        return error.HttpRequestError switch
        {
            HttpRequestError.NameResolutionError => ADOError.Network(message: "Can't reach Azure DevOps."),
            HttpRequestError.ProxyTunnelError => ADOError.Network(message: "The proxy didn't let BriefBar reach Azure DevOps."),
            HttpRequestError.SecureConnectionError => ADOError.Network(message: "Couldn't connect to Azure DevOps securely."),
            _ => ADOError.Network(message: "Couldn't connect to Azure DevOps."),
        };
    }

    async Task<AccessToken> AccessTokenAsync(CancellationToken cancellationToken)
    {
        try
        {
            return await Tokens.TokenAsync(cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (AuthException error)
        {
            throw new ADOException(error: ADOError.FromAuth(error: error.Error), innerException: error);
        }
    }
}
