using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// A pull request's key: organization names are case-insensitive in Azure DevOps.
public sealed class PRKeyTests
{
    /// `Contoso/7` is `contoso/7`, and says itself as it was spelled.
    [Fact]
    public void ComparesOrganizationsIgnoringCase()
    {
        var listed = new PRKey(Organization: "contoso", Number: 7);
        var linked = new PRKey(Organization: "Contoso", Number: 7);
        Assert.Equal(expected: listed, actual: linked);
        Assert.True(condition: listed == linked);
        Assert.Equal(expected: listed.GetHashCode(), actual: linked.GetHashCode());
        Assert.Equal(expected: 0, actual: listed.CompareTo(other: linked));
        Assert.Single(collection: new HashSet<PRKey> { listed, linked, new(Organization: "CONTOSO", Number: 7) });
        Assert.Equal(expected: "Contoso/7", actual: linked.ToString());

        Assert.NotEqual(expected: listed, actual: new PRKey(Organization: "contoso", Number: 8));
        Assert.NotEqual(expected: listed, actual: new PRKey(Organization: "fabrikam", Number: 7));
        Assert.True(condition: new PRKey(Organization: "Contoso", Number: 8) > listed);
        Assert.True(condition: new PRKey(Organization: "Fabrikam", Number: 1) > listed);
    }
}
