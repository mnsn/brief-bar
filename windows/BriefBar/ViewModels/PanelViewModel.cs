using System.Collections.ObjectModel;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// What the panel shows: its header, a banner when its section can't show everything, its brief, and its groups of
/// rows. One panel serves every item, so it's updated in place, keeping its list's scroll position and focus.
public sealed class PanelViewModel : Observable
{
    /// BriefBar's own blue, for the Overview's tile.
    const uint OverviewTint = 0xFF0067C0u;

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

    public ObservableCollection<BriefLineViewModel> Brief { get; } = [];

    public bool HasBrief { get; private set => Set(storage: ref field, value: value); }

    public Brush SparkleBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public ObservableCollection<RowGroupViewModel> Groups { get; } = [];

    public bool IsEmpty { get; private set => Set(storage: ref field, value: value); }

    public string EmptyText { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// Made-up data, said in the footer so it's never mistaken for yours.
    public bool IsDemo { get; private set => Set(storage: ref field, value: value); }

    public void Update(PanelTarget target, IReadOnlyList<SectionSnapshot> snapshots, ThemePalette palette, DateTimeOffset now, bool isDemo)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        ArgumentNullException.ThrowIfNull(argument: palette);
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
        ShowGroups(groups: PanelLists.ForOverview(snapshots: snapshots), section: null, palette: palette, now: now);
        EmptyText = snapshots.Count == 0
            ? "BriefBar for Windows doesn't read any source yet: they arrive one at a time. Start it with --demo to see made-up data."
            : "Nothing needs you right now.";
    }

    void ShowSection(SectionId section, SectionSnapshot? snapshot, ThemePalette palette, DateTimeOffset now)
    {
        var info = snapshot?.Info ?? Sections.InBarOrder.FirstOrDefault(predicate: candidate => candidate.Id == section);
        TileGlyph = info?.Glyph ?? IconKey.Stack;
        TileBrush = palette.Tint(tint: info?.Tint ?? OverviewTint);
        TileGlyphBrush = palette.OnTint;
        Title = info?.Title ?? section.RawValue;
        if (snapshot is null)
        {
            Subtitle = info?.SourceName ?? string.Empty;
            IsLive = false;
            ShowProblem(snapshot: null, now: now);
            ShowBrief(lines: [], palette: palette);
            ShowGroups(groups: [], section: section, palette: palette, now: now);
            EmptyText = "This source is off.";
            return;
        }
        var status = StatusWords.Of(status: snapshot.Status, now: now);
        var conditionIsReady = snapshot.Status.Condition == SectionCondition.Ready;
        Subtitle = conditionIsReady && status.Length > 0 ? snapshot.Info.SourceName + " · " + status : snapshot.Info.SourceName;
        IsLive = snapshot.Status.IsLive && conditionIsReady;
        ShowProblem(snapshot: snapshot, now: now);
        ShowBrief(lines: PanelLists.Brief(snapshots: [snapshot]), palette: palette);
        ShowGroups(groups: PanelLists.ForSection(snapshot: snapshot), section: section, palette: palette, now: now);
        EmptyText = snapshot.Status.Condition == SectionCondition.Starting ? "Reading…" : "Nothing here right now.";
    }

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

    void ShowGroups(IReadOnlyList<PanelGroup> groups, SectionId? section, ThemePalette palette, DateTimeOffset now)
    {
        CollectionSync.Sync(
            items: Groups,
            values: groups,
            matches: (item, group) => item.Key == group.Key,
            create: group =>
            {
                var created = new RowGroupViewModel(key: group.Key);
                created.Update(group: group, section: section, palette: palette, now: now);
                return created;
            },
            update: (item, group) => item.Update(group: group, section: section, palette: palette, now: now));
        IsEmpty = groups.Count == 0;
    }
}
