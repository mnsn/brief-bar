using BriefBar.Core.Logging;

namespace BriefBar.Core.Presentation;

/// What a panel shows: the Overview, or one section.
public readonly record struct PanelTarget(SectionId? Section) : ILoggable
{
    public static PanelTarget Overview { get; } = new(Section: null);

    public bool IsOverview => Section is null;

    public static PanelTarget Of(SectionId section) => new(Section: section);

    public override string ToString() => Section?.RawValue ?? "overview";
}
