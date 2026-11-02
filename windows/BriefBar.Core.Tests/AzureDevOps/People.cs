using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Made-up people, as the Swift tests' `People`.
internal static class People
{
    public static Person Me { get; } = new(id: "11111111-1111-1111-1111-111111111111", name: "Robin Diaz");

    public static Person Sam { get; } = new(id: "22222222-2222-2222-2222-222222222222", name: "Sam Rivera");

    public static Person Priya { get; } = new(id: "33333333-3333-3333-3333-333333333333", name: "Priya Shah");

    public static Person Alex { get; } = new(id: "44444444-4444-4444-4444-444444444444", name: "Alex Kim");

    public static Person Bot { get; } = new(id: "55555555-5555-5555-5555-555555555555", name: "Shop Build Service", isBot: true);
}
