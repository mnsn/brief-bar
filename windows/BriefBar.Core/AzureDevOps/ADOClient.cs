using System.Net;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// Reads from Azure DevOps. It only ever sends GET requests, each with a bearer token from the Azure CLI's sign-in:
/// BriefBar never changes anything there. No cookies and no cache: every request carries its own token, through the
/// system's proxy, to where it's sent only: it follows no redirect (`Redirects`). A rejected token is replaced once; an
/// organization in another directory than the token's, which Azure DevOps names as it rejects it, is read with a token
/// from there, once the Azure CLI is signed in there (`ADOErrorKind.OtherDirectory` until then). Asked to slow down, it
/// sends nothing until the time Azure DevOps gave (`Retry-After`, in seconds or as a date), or for a minute when it doesn't
/// say. The Mac's `ADOClient`.
public sealed class ADOClient : IDisposable
{
    /// How long to wait when Azure DevOps asks to slow down without saying for how long.
    internal static readonly TimeSpan RetryAfterUnsaid = TimeSpan.FromSeconds(value: 60);

    readonly HttpClient http;
    readonly RateLimitGate gate;
    readonly TimeProvider time;
    /// The directory of each organization in another one than your sign-in's, as Azure DevOps named it.
    readonly OrganizationDirectories directories = new();

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

    /// The only way requests are made: GET, with a bearer token for the organization's directory, tried again once with a
    /// new token if Azure DevOps rejects it, or answers with its sign-in page, and once with a token from the
    /// organization's own directory if Azure DevOps names another one than the token's.
    internal async Task<byte[]> DataAsync(Uri url, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(argument: url);
        if (gate.RemainingWait() is { } wait)
        {
            throw new ADOException(error: ADOError.Throttled(retryAfter: wait));
        }
        var organization = OrganizationOf(url: url);
        var tenant = organization is null ? null : directories.TenantOf(organization: organization);
        AccessToken token;
        try
        {
            token = await AccessTokenAsync(tenant: tenant, organization: organization, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (ADOException error) when (error.Error.Kind == ADOErrorKind.OtherDirectory)
        {
            // Signed out of the directory it was in: with a token from yours, Azure DevOps names the one it's in now, which
            // may be another.
            if (organization is not null)
            {
                directories.Forget(organization: organization);
            }
            tenant = null;
            token = await AccessTokenAsync(tenant: null, organization: organization, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        }
        var refreshed = false;
        var movedDirectory = false;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            using var request = Request(url: url, token: token.Value);
            using var response = await SendAsync(request: request, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
            var retryAfter = RetryAfter.Wait(value: Header(response: response, name: "Retry-After"), now: time.GetUtcNow());
            if (retryAfter is { } asked)
            {
                gate.Hold(wait: asked);
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
                    // 203 with a sign-in page is how Azure DevOps answers a request it didn't authenticate. An organization in
                    // another directory names its own: once a token from there works, it's read with one from there.
                    if (organization is not null && !movedDirectory && OtherDirectory(response: response, token: token) is { } other)
                    {
                        movedDirectory = true;
                        tenant = other;
                        token = await AccessTokenAsync(tenant: other, organization: organization, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                        directories.Remember(tenant: other, organization: organization);
                        continue;
                    }
                    if (!refreshed)
                    {
                        refreshed = true;
                        Tokens.Invalidate(tenant: tenant);
                        token = await AccessTokenAsync(tenant: tenant, organization: organization, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
                        continue;
                    }
                    throw new ADOException(error: ADOError.Unauthorized);
                case 403:
                    throw new ADOException(error: ADOError.Forbidden);
                case 404:
                    throw new ADOException(error: ADOError.NotFound);
                case 429 or 503:
                    // Asked to slow down without saying for how long: nothing goes out for a minute, as if it had said so,
                    // whichever engine asks next.
                    var slowDown = retryAfter ?? RetryAfterUnsaid;
                    gate.Hold(wait: slowDown);
                    throw new ADOException(error: ADOError.Throttled(retryAfter: slowDown));
                case >= 300 and < 400 when Redirects.OtherHost(location: response.Headers.Location, requested: url) is not null:
                    // Without the host, as the Mac's says it: one can carry an organization's name.
                    throw new ADOException(error: ADOError.Network(message: "Azure DevOps redirected BriefBar to another host, which it doesn't connect to."));
                default:
                    // A redirect that stays on the same host too: Azure DevOps answers each request where it's sent.
                    throw new ADOException(error: ADOError.Http(status: status));
            }
        }
        throw new ADOException(error: ADOError.Unauthorized);
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

    /// How long Azure DevOps asked BriefBar to wait still, or null when it may send again: whichever reader asks next waits.
    internal TimeSpan? RemainingWait() => gate.RemainingWait();

    /// The organization a request reads, by name: the first part of a dev.azure.com path. Null for one that reads no
    /// organization, such as finding yours.
    internal static string? OrganizationOf(Uri url)
    {
        ArgumentNullException.ThrowIfNull(argument: url);
        if (!url.IsAbsoluteUri || !string.Equals(a: url.Host, b: "dev.azure.com", comparisonType: StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }
        var first = url.AbsolutePath.Split(separator: '/', options: StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return first is null ? null : Uri.UnescapeDataString(stringToUnescape: first);
    }

    /// The directory an organization that rejected `token` is in, when it's another one than the token's: Azure DevOps
    /// names the organization's directories in `X-VSS-ResourceTenant`. Null when it names the token's, or none, or when the
    /// token doesn't say its own, which can't be told from the organization's then.
    internal static string? OtherDirectory(HttpResponseMessage response, AccessToken token)
    {
        ArgumentNullException.ThrowIfNull(argument: response);
        ArgumentNullException.ThrowIfNull(argument: token);
        if (TenantId.From(text: token.Tenant) is not { } tokenTenant)
        {
            return null;
        }
        var named = ResourceTenants(header: AllValues(response: response, name: "X-VSS-ResourceTenant"));
        return named.Count == 0 || named.Contains(item: tokenTenant) ? null : named[0];
    }

    /// The directories in `X-VSS-ResourceTenant`'s value, lowercased: only directories' IDs, which are GUIDs, since one goes
    /// to `az login --tenant`; and not the empty one (`TenantId`).
    internal static List<string> ResourceTenants(string? header) =>
        (header ?? string.Empty).Split(separator: ',').Select(selector: value => TenantId.From(text: value)).OfType<string>().ToList();

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

    /// The first value of the header `name`, as Azure DevOps sent it.
    static string? Header(HttpResponseMessage response, string name) =>
        response.Headers.NonValidated.TryGetValues(headerName: name, values: out var values) ? values.FirstOrDefault() : null;

    /// Every value of the header `name`, as Azure DevOps sent it, in one list, or null without one.
    static string? AllValues(HttpResponseMessage response, string name) =>
        response.Headers.NonValidated.TryGetValues(headerName: name, values: out var values) ? string.Join(separator: ',', values: values) : null;

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

    /// A token for `tenant`'s directory, or for your sign-in's. When the Azure CLI isn't signed in to an organization's
    /// directory, that's the organization's problem, which signing in there fixes: the others are still read.
    async Task<AccessToken> AccessTokenAsync(string? tenant, string? organization, CancellationToken cancellationToken)
    {
        try
        {
            return await Tokens.TokenAsync(tenant: tenant, cancellationToken: cancellationToken).ConfigureAwait(continueOnCapturedContext: false);
        }
        catch (AuthException error)
        {
            if (tenant is not null && organization is not null && error.Error.Kind == AuthErrorKind.SignedOut)
            {
                throw new ADOException(error: ADOError.OtherDirectory(organization: organization, tenant: tenant), innerException: error);
            }
            throw new ADOException(error: ADOError.FromAuth(error: error.Error), innerException: error);
        }
    }
}
