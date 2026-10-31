namespace BriefBar.Core.Presentation;

/// What a section shows at one moment: how it stands, its groups in order, its rows in their groups' order, and its
/// things that are in a state, each in a sentence, for a brief.
public sealed record SectionSnapshot(
    SectionInfo Info,
    SectionStatus Status,
    IReadOnlyList<RowGroup> Groups,
    IReadOnlyList<ItemRow> Rows,
    IReadOnlyList<BriefLine> BriefLines)
{
    /// What its panel can ask its source to do, on buttons at its foot, such as "Open GitHub Copilot".
    public IReadOnlyList<PanelCommand> Commands { get; init; } = [];

    /// What its panel says when it has nothing to list, such as "No sessions yet"; a general sentence when null.
    public string? EmptyText { get; init; }

    /// What its panel says when nothing in it is counted, such as Copilot's "All quiet" over its idle sessions; none for
    /// a section that just lists nothing.
    public QuietNote? Quiet { get; init; }

    /// Its rows' states, counted: the bar's counts are always its rows'.
    public StateCounts Counts
    {
        get
        {
            var counts = new StateCounts();
            foreach (var row in Rows)
            {
                if (row.State is { } state)
                {
                    counts = counts.Adding(state: state, count: 1);
                }
            }
            return counts;
        }
    }

    /// A section that's starting, with nothing to show yet.
    public static SectionSnapshot Starting(SectionInfo info) => new(
        Info: info, Status: SectionStatus.Starting, Groups: [], Rows: [], BriefLines: []);
}
