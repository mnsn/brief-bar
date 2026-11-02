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

    /// What the banner offers for its problem or out-of-date list, such as signing in.
    public PanelCommand? ProblemCommand { get; init; }

    /// What the banner says after its problem, in its panel only, such as what signing in does there: not in the bar's
    /// tooltip, which says the problem alone.
    public string? ProblemHint { get; init; }

    /// What its panel says when nothing in it is counted, such as Copilot's "All quiet" over its idle sessions; none for
    /// a section that just lists nothing.
    public QuietNote? Quiet { get; init; }

    /// What its panel says about what it shows, beside it, such as that there's more on GitHub.
    public IReadOnlyList<SectionNotice> Notices { get; init; } = [];

    /// Who it reads as, at its panel's foot, such as the GitHub CLI's login.
    public SectionAccount? Account { get; init; }

    /// How its list can be sorted, from a menu at the top of its panel; none for a list in one order.
    public SectionSort? Sort { get; init; }

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
