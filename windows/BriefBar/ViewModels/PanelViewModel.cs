using System.Collections.ObjectModel;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// What the panel shows: its header, with a menu that sorts its list where it can be sorted, a banner when its section
/// can't show everything, its brief, a word when all is quiet, its groups of rows, and what its footer can do. One panel
/// serves every item, so it's updated in place, keeping its list's scroll position and focus.
public sealed class PanelViewModel : Observable
{
    /// BriefBar's own blue, for the Overview's tile.
    const uint OverviewTint = 0xFF0067C0u;

    /// The groups you unfolded since the panel opened.
    readonly HashSet<string> unfolded = new(comparer: StringComparer.Ordinal);
    ThemePalette? palette;
    DateTimeOffset now;

    public PanelTarget Target { get; private set => Set(storage: ref field, value: value); }

    public IconKey TileGlyph { get; private set => Set(storage: ref field, value: value); }

    public Brush TileBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public Brush TileGlyphBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public string Title { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string Subtitle { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// It follows changes as they happen, as Copilot and Teams do.
    public bool IsLive { get; private set => Set(storage: ref field, value: value); }

    public Brush LiveBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public bool HasProblem { get; private set => Set(storage: ref field, value: value); }

    public string ProblemTitle { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string ProblemMessage { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// What the banner's button does, such as reviewing what a paused source reads.
    public PanelCommand? ProblemCommand { get; private set => Set(storage: ref field, value: value); }

    /// The section the banner is about: in the Overview, not the panel's own.
    public SectionId? ProblemSection { get; private set => Set(storage: ref field, value: value); }

    public bool HasProblemCommand { get; private set => Set(storage: ref field, value: value); }

    public string ProblemCommandTitle { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public ObservableCollection<BriefLineViewModel> Brief { get; } = [];

    public bool HasBrief { get; private set => Set(storage: ref field, value: value); }

    public Brush SparkleBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    /// "All quiet", over "3 idle sessions", when the section counts nothing.
    public bool HasQuiet { get; private set => Set(storage: ref field, value: value); }

    public string QuietTitle { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string QuietDetail { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// What the section says about what it shows, beside it, such as that there's more on GitHub.
    public IReadOnlyList<NoticeViewModel> Notices { get; private set => Set(storage: ref field, value: value); } = [];

    public bool HasNotices { get; private set => Set(storage: ref field, value: value); }

    /// Who the section reads as, at its foot, such as the GitHub CLI's login.
    public string AccountName { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// What the account is: "Signed in to the GitHub CLI as robin".
    public string AccountHelp { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasAccount { get; private set => Set(storage: ref field, value: value); }

    /// How the section's list can be sorted, from a menu at the top of the panel; none in the Overview.
    public SectionSort? Sort { get; private set => Set(storage: ref field, value: value); }

    public bool HasSort { get; private set => Set(storage: ref field, value: value); }

    /// What Narrator calls the sort menu's button, with the order in use: "Sort pull requests: By status".
    public string SortName { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string SortHelp { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public ObservableCollection<RowGroupViewModel> Groups { get; } = [];

    public bool IsEmpty { get; private set => Set(storage: ref field, value: value); }

    public string EmptyText { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// With no source on, the empty Overview offers Settings, where you turn one on.
    public bool OffersSettings { get; private set => Set(storage: ref field, value: value); }

    /// What the section's footer offers, such as "Open GitHub Copilot".
    public IReadOnlyList<PanelCommand> Commands { get; private set => Set(storage: ref field, value: value); } = [];

    /// What the section's footer offers as icons beside Settings, such as Azure DevOps' refresh.
    public IReadOnlyList<PanelCommand> IconCommands { get; private set => Set(storage: ref field, value: value); } = [];

    /// Made-up data, said in the footer so it's never mistaken for yours.
    public bool IsDemo { get; private set => Set(storage: ref field, value: value); }

    /// The source whose page Settings opens at from this panel: its section's, or none for the Overview.
    public SourceId? Source => Target.Section?.Source;

    /// The list it shows was sorted another way, as you chose another order from its sort menu: the panel shows it from
    /// its top again.
    public event EventHandler? Resorted;

    public void Update(PanelTarget target, IReadOnlyList<SectionSnapshot> snapshots, ThemePalette palette, DateTimeOffset now, bool isDemo)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        ArgumentNullException.ThrowIfNull(argument: palette);
        if (target != Target)
        {
            unfolded.Clear();
        }
        // The order the same list was in, before this update.
        var sortedBefore = target == Target ? Sort?.Chosen : null;
        this.palette = palette;
        this.now = now;
        Target = target;
        IsDemo = isDemo;
        LiveBrush = palette.Fill(state: ItemState.Done);
        SparkleBrush = palette.Glyph(tint: 0xFF8B5CF6u);
        if (target.Section is { } section)
        {
            ShowSection(section: section, snapshot: snapshots.FirstOrDefault(predicate: snapshot => snapshot.Info.Id == section), palette: palette, now: now);
        }
        else
        {
            ShowOverview(snapshots: snapshots, palette: palette, now: now);
        }
        if (sortedBefore is not null && Sort?.Chosen is { } sorted && sorted != sortedBefore)
        {
            Resorted?.Invoke(sender: this, e: EventArgs.Empty);
        }
    }

    /// As the panel opens: every group that folds starts folded again, as on the Mac.
    public void FoldAll() => unfolded.Clear();

    /// Shows or hides the rows of `group`, a group that folds.
    public void ToggleFold(RowGroupViewModel group)
    {
        ArgumentNullException.ThrowIfNull(argument: group);
        if (!group.IsFoldable || palette is null)
        {
            return;
        }
        var folded = !group.IsFolded;
        if (folded)
        {
            unfolded.Remove(item: group.Key);
        }
        else
        {
            unfolded.Add(item: group.Key);
        }
        group.Fold(folded: folded, palette: palette, now: now);
    }

    void ShowOverview(IReadOnlyList<SectionSnapshot> snapshots, ThemePalette palette, DateTimeOffset now)
    {
        TileGlyph = IconKey.Stack;
        TileBrush = palette.Tint(tint: OverviewTint);
        TileGlyphBrush = palette.OnTint;
        Title = "Overview";
        Subtitle = snapshots.Count == 0 ? "No source is on" : "Every source, by what it needs from you";
        IsLive = false;
        var trouble = snapshots.FirstOrDefault(predicate: snapshot => snapshot.Status.Condition
            is SectionCondition.Problem or SectionCondition.Stale or SectionCondition.Paused);
        ShowProblem(snapshot: trouble, now: now);
        ShowBrief(lines: PanelLists.Brief(snapshots: snapshots), palette: palette);
        ShowQuiet(quiet: null);
        ShowNotices(notices: []);
        ShowAccount(account: null);
        ShowSort(sort: null);
        ShowGroups(groups: PanelLists.ForOverview(snapshots: snapshots), section: null, palette: palette, now: now);
        EmptyText = snapshots.Count == 0
            ? "No source is on. Turn one on in Settings, and what needs you shows here."
            : "Nothing needs you right now.";
        OffersSettings = snapshots.Count == 0;
        Commands = [];
        IconCommands = [];
    }

    void ShowSection(SectionId section, SectionSnapshot? snapshot, ThemePalette palette, DateTimeOffset now)
    {
        var info = snapshot?.Info ?? Sections.InBarOrder.FirstOrDefault(predicate: candidate => candidate.Id == section);
        TileGlyph = info?.Glyph ?? IconKey.Stack;
        TileBrush = palette.Tint(tint: info?.Tint ?? OverviewTint);
        TileGlyphBrush = palette.OnTint;
        Title = info?.Title ?? section.RawValue;
        OffersSettings = false;
        if (snapshot is null)
        {
            Subtitle = info?.SourceName ?? string.Empty;
            IsLive = false;
            ShowProblem(snapshot: null, now: now);
            ShowBrief(lines: [], palette: palette);
            ShowQuiet(quiet: null);
            ShowNotices(notices: []);
            ShowAccount(account: null);
            ShowSort(sort: null);
            ShowGroups(groups: [], section: section, palette: palette, now: now);
            EmptyText = "This source is off.";
            Commands = [];
            IconCommands = [];
            return;
        }
        var status = StatusWords.Of(status: snapshot.Status, now: now);
        var conditionIsReady = snapshot.Status.Condition == SectionCondition.Ready;
        Subtitle = conditionIsReady && status.Length > 0 ? snapshot.Info.SourceName + " · " + status : snapshot.Info.SourceName;
        IsLive = snapshot.Status.IsLive && conditionIsReady;
        ShowProblem(snapshot: snapshot, now: now);
        ShowBrief(lines: PanelLists.Brief(snapshots: [snapshot]), palette: palette);
        ShowQuiet(quiet: snapshot.Quiet);
        ShowNotices(notices: snapshot.Notices);
        ShowAccount(account: snapshot.Account);
        ShowSort(sort: snapshot.Sort);
        ShowGroups(groups: PanelLists.ForSection(snapshot: snapshot), section: section, palette: palette, now: now);
        // A section may say what it's doing as it starts, such as finding your organizations.
        EmptyText = snapshot.EmptyText
            ?? (snapshot.Status.Condition == SectionCondition.Starting ? "Reading…" : "Nothing here right now.");
        // A paused section's review is on its banner.
        IReadOnlyList<PanelCommand> commands = snapshot.Status.Condition == SectionCondition.Paused ? [] : snapshot.Commands;
        var titled = FooterCommands(commands: commands, iconOnly: false);
        if (!titled.SequenceEqual(second: Commands))
        {
            Commands = titled;
        }
        var icons = FooterCommands(commands: commands, iconOnly: true);
        if (!icons.SequenceEqual(second: IconCommands))
        {
            IconCommands = icons;
        }
    }

    static List<PanelCommand> FooterCommands(IReadOnlyList<PanelCommand> commands, bool iconOnly) =>
        [.. commands.Where(predicate: command => command.IconOnly == iconOnly)];

    /// A banner for a section that can't show everything: why, and what to do.
    void ShowProblem(SectionSnapshot? snapshot, DateTimeOffset now)
    {
        var condition = snapshot?.Status.Condition;
        HasProblem = condition is SectionCondition.Problem or SectionCondition.Stale or SectionCondition.Paused;
        ProblemTitle = condition switch
        {
            SectionCondition.Problem => snapshot!.Info.SourceName + " can't read",
            SectionCondition.Stale => "Couldn't refresh " + snapshot!.Info.SourceName,
            SectionCondition.Paused => snapshot!.Info.SourceName + " is paused",
            _ => string.Empty,
        };
        ProblemMessage = HasProblem ? StatusWords.Of(status: snapshot!.Status, now: now) : string.Empty;
        ProblemSection = HasProblem ? snapshot!.Info.Id : null;
        ProblemCommand = condition switch
        {
            SectionCondition.Paused => snapshot!.Commands.FirstOrDefault(predicate: command => command.Key == AppCommands.ReviewSource),
            SectionCondition.Problem or SectionCondition.Stale => snapshot!.ProblemCommand,
            _ => null,
        };
        HasProblemCommand = ProblemCommand is not null;
        ProblemCommandTitle = ProblemCommand?.Title ?? string.Empty;
    }

    void ShowBrief(IReadOnlyList<BriefLine> lines, ThemePalette palette)
    {
        CollectionSync.Sync(
            items: Brief,
            values: lines,
            matches: (item, line) => item.Id == line.Id,
            create: line => new BriefLineViewModel(id: line.Id) { Sentence = line.Sentence, DotBrush = palette.Fill(state: line.State) },
            update: (item, line) =>
            {
                item.Sentence = line.Sentence;
                item.DotBrush = palette.Fill(state: line.State);
            });
        HasBrief = lines.Count > 0;
    }

    void ShowQuiet(QuietNote? quiet)
    {
        HasQuiet = quiet is not null;
        QuietTitle = quiet?.Title ?? string.Empty;
        QuietDetail = quiet?.Detail ?? string.Empty;
    }

    /// Only notices that changed are put on screen again, not the same ones at every refresh.
    void ShowNotices(IReadOnlyList<SectionNotice> notices)
    {
        if (!notices.SequenceEqual(second: Notices.Select(selector: shown => shown.Notice)))
        {
            Notices = [.. notices.Select(selector: notice => new NoticeViewModel(notice: notice))];
        }
        HasNotices = notices.Count > 0;
    }

    void ShowAccount(SectionAccount? account)
    {
        AccountName = account?.Name ?? string.Empty;
        AccountHelp = account?.Help ?? string.Empty;
        HasAccount = account is not null;
    }

    void ShowSort(SectionSort? sort)
    {
        Sort = sort;
        HasSort = sort is not null;
        SortName = sort is null ? string.Empty : sort.Name + (sort.ChosenChoice is { } chosen ? ": " + chosen.Title : string.Empty);
        SortHelp = sort?.Help ?? string.Empty;
    }

    void ShowGroups(IReadOnlyList<PanelGroup> groups, SectionId? section, ThemePalette palette, DateTimeOffset now)
    {
        CollectionSync.Sync(
            items: Groups,
            values: groups,
            matches: (item, group) => item.Key == group.Key,
            create: group =>
            {
                var created = new RowGroupViewModel(key: group.Key);
                created.Update(group: group, section: section, palette: palette, now: now, isFolded: !unfolded.Contains(item: group.Key));
                return created;
            },
            update: (item, group) => item.Update(group: group, section: section, palette: palette, now: now, isFolded: !unfolded.Contains(item: group.Key)));
        IsEmpty = groups.Count == 0 && !HasQuiet;
    }
}
