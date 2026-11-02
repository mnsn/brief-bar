using System.Net;

namespace BriefBar.Core.Tests;

/// Where a redirect would send a request: another host is named, in ASCII; one that stays on the request's host isn't.
public sealed class RedirectsTests
{
    static readonly Uri requested = new(uriString: "https://api.example.com/graphql");

    [Theory]
    [InlineData("https://sso.example.org/login?from=1", "sso.example.org")]
    [InlineData("http://api.example.com.example.net/graphql", "api.example.com.example.net")]
    [InlineData("https://bücher.example/graphql", "xn--bcher-kva.example")]
    public void NamesTheOtherHost(string location, string host) =>
        Assert.Equal(expected: host, actual: Redirects.OtherHost(location: new Uri(uriString: location), requested: requested));

    /// A reference without a scheme, `//host/path`, is to that host.
    [Fact]
    public void NamesTheHostOfAReferenceWithoutAScheme() =>
        Assert.Equal(expected: "elsewhere.example.net", actual: Redirects.OtherHost(location: new Uri(uriString: "//elsewhere.example.net/graphql", uriKind: UriKind.RelativeOrAbsolute), requested: requested));

    /// One that stays on the request's host, whatever its path, case or scheme, or that has no location, names no host.
    [Theory]
    [InlineData("https://api.example.com/graphql/")]
    [InlineData("HTTPS://API.EXAMPLE.COM/other")]
    [InlineData("http://api.example.com:8080/graphql")]
    [InlineData("/login")]
    [InlineData("graphql?again=1")]
    [InlineData(null)]
    public void OneThatStaysNamesNoHost(string? location) =>
        Assert.Null(@object: Redirects.OtherHost(location: location is null ? null : new Uri(uriString: location, uriKind: UriKind.RelativeOrAbsolute), requested: requested));

    /// One that doesn't say where names no host either, rather than throwing: a location that .NET reads from an answer's
    /// header but can't resolve against the request, as `//`, or one without a host, as `about:blank`.
    [Theory]
    [InlineData("//")]
    [InlineData("///login")]
    [InlineData("http:")]
    [InlineData("http:/x")]
    [InlineData("about:blank")]
    public void OneThatDoesntSayWhereNamesNoHost(string location)
    {
        using var response = new HttpResponseMessage(statusCode: HttpStatusCode.Found);
        response.Headers.TryAddWithoutValidation(name: "Location", value: location);
        var read = response.Headers.Location;
        Assert.NotNull(@object: read);
        Assert.Null(@object: Redirects.OtherHost(location: read, requested: requested));
    }
}
