namespace BriefBar.Core.Presentation;

/// Who a section reads as, at its panel's foot, as the Mac's GitHub popover shows the GitHub CLI's login: its `Name`, and
/// what it is, for its tooltip (`Help`).
public sealed record SectionAccount(string Name, string Help);
