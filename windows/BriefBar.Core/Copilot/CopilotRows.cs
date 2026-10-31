using System.Globalization;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Copilot;

/// What the Copilot section shows, from its store: how it stands, its groups and rows, its brief, and what its panel can
/// do. The Mac's `CopilotSource` menu-bar parts, `MenuPanelView` and `SessionRowView`, as data.
public static class CopilotRows
{
    /// The deepest a row is indented under the session that started it.
    public const int MaxIndentLevels = 3;

    /// The longest name a ↳ tag shows in full; its tooltip has all of it.
    public const int TagNameLimit = 24;

    /// From here, a session's context usage is worth a look: Copilot compacts a conversation at about 80% of its window.
    public const double ContextWarningFraction = 0.7;

    /// What the section shows as `store` and `settings` stand now.
    public static SectionSnapshot Snapshot(SessionStore store, CopilotSettings settings)
    {
        ArgumentNullException.ThrowIfNull(argument: store);
        ArgumentNullException.ThrowIfNull(argument: settings);
        var info = Sections.CopilotSessions;
        if (!store.HasLoaded)
        {
            return SectionSnapshot.Starting(info: info);
        }
        var sessions = store.Sessions;
        var showContextUsage = settings.ShowContextUsage;
        var rows = sessions.Select(selector: session => Row(session: session, canOpen: store.CanOpen, showContextUsage: showContextUsage)).ToList();
        var briefLines = sessions
            .Where(predicate: session => session.Phase.State() is not null)
            .Select(selector: session => new BriefLine(
                Id: session.Id,
                Section: info.Id,
                State: session.Phase.State()!.Value,
                Date: session.Since,
                Sentence: session.BriefSentence))
            .ToList();
        return new SectionSnapshot(Info: info, Status: Status(problem: store.Problem, hasSessions: sessions.Count > 0), Groups: Groups, Rows: rows, BriefLines: briefLines)
        {
            Commands = store.AppInstalled ? [new PanelCommand(Key: CopilotCommands.OpenApp, Title: "Open GitHub Copilot", Opens: true)] : [],
            Quiet = store.Counts.Active == 0 ? new QuietNote(Title: "All quiet", Detail: IdleWords(idle: store.Counts.Idle)) : null,
        };
    }

    /// Under "All quiet": "No sessions yet", "1 idle session", "34 idle sessions".
    public static string IdleWords(int idle) => idle switch
    {
        0 => "No sessions yet",
        1 => "1 idle session",
        _ => idle.ToString(provider: CultureInfo.InvariantCulture) + " idle sessions",
    };

    /// Each group, in the list's order. Done and Stopped can be cleared; Idle starts folded, as on the Mac.
    public static IReadOnlyList<RowGroup> Groups { get; } = DisplayPhases.All.Select(selector: phase => new RowGroup(
        Key: GroupKey(phase: phase), Title: phase.Title(), State: phase.State())
    {
        Commands = phase is DisplayPhase.Done or DisplayPhase.Stopped
            ? [new PanelCommand(Key: CopilotCommands.Clear, Title: "Clear", Help: "Move these sessions to Idle")]
            : [],
        IsFolded = phase == DisplayPhase.Idle,
    }).ToList();

    public static string GroupKey(DisplayPhase phase) => phase switch
    {
        DisplayPhase.NeedsYou => "needsYou",
        DisplayPhase.Running => "running",
        DisplayPhase.Done => "done",
        DisplayPhase.Stopped => "stopped",
        DisplayPhase.Idle => "idle",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(phase), actualValue: phase, message: "Not a phase."),
    };

    public static DisplayPhase? Phase(string groupKey) =>
        DisplayPhases.All.Cast<DisplayPhase?>().FirstOrDefault(predicate: phase => GroupKey(phase: phase!.Value) == groupKey);

    /// One session's row: its reason's icon, its name, where it stands, what it's about, and what clicking it does.
    public static ItemRow Row(SessionSnapshot session, bool canOpen, bool showContextUsage)
    {
        ArgumentNullException.ThrowIfNull(argument: session);
        var otherParent = OtherParent(session: session);
        var meter = showContextUsage && session.ContextUsage is { Limit: > 0 } usage ? Meter(usage: usage) : null;
        return new ItemRow
        {
            Id = session.Id,
            Section = SectionId.CopilotSessions,
            Group = GroupKey(phase: session.Phase),
            State = session.Phase.State(),
            Icon = Icon(reason: session.Reason),
            Title = session.DisplayName,
            Status = Subtitle(session: session),
            Detail = session.Detail,
            Date = session.Since,
            Commands = Commands(session: session, canOpen: canOpen, otherParent: otherParent),
            ToolTip = ToolTip(session: session, canOpen: canOpen, otherParent: otherParent, meter: meter),
            Depth = Math.Min(val1: session.Depth, val2: MaxIndentLevels),
            Tag = otherParent is null ? null : Tag(parent: otherParent, canOpen: canOpen),
            Meter = meter,
        };
    }

    /// The icon of where it stands; an idle session keeps the one it ended with.
    public static IconKey Icon(StatusReason reason) => reason switch
    {
        StatusReason.Question => IconKey.ChatQuestion,
        StatusReason.PlanApproval => IconKey.ClipboardTaskList,
        StatusReason.Permission => IconKey.ShieldLock,
        StatusReason.Working => IconKey.ArrowSync,
        StatusReason.Starting => IconKey.Clock,
        StatusReason.Relayed => IconKey.ArrowReply,
        StatusReason.Finished => IconKey.Checkmark,
        StatusReason.Interrupted => IconKey.RecordStop,
        StatusReason.Failed => IconKey.DismissCircle,
        StatusReason.Unresponsive => IconKey.Warning,
        StatusReason.Idle => IconKey.WeatherMoon,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(reason), actualValue: reason, message: "Not a reason."),
    };

    /// Where it stands, and where it works: "Waiting for your answer · shop-web", or "· Chat" for a chat.
    public static string Subtitle(SessionSnapshot session)
    {
        ArgumentNullException.ThrowIfNull(argument: session);
        if (!string.IsNullOrEmpty(value: session.ProjectName))
        {
            return session.Headline + " · " + session.ProjectName;
        }
        return session.IsChat ? session.Headline + " · Chat" : session.Headline;
    }

    /// A name cut to `TagNameLimit` characters.
    public static string ShortName(string name)
    {
        ArgumentNullException.ThrowIfNull(argument: name);
        var info = new StringInfo(value: name);
        return info.LengthInTextElements <= TagNameLimit
            ? name
            : info.SubstringByTextElements(startingTextElement: 0, lengthInTextElements: TagNameLimit - 1).TrimEnd() + "…";
    }

    /// "90K", "1.2M": a count of tokens, short.
    public static string Compact(long value) => value switch
    {
        < 1_000 => value.ToString(provider: CultureInfo.InvariantCulture),
        < 1_000_000 => Scaled(value: value / 1_000.0, suffix: "K"),
        < 1_000_000_000 => Scaled(value: value / 1_000_000.0, suffix: "M"),
        _ => Scaled(value: value / 1_000_000_000.0, suffix: "B"),
    };

    static RowMeter Meter(ContextUsage usage) => new(
        Fraction: usage.Fraction,
        Text: usage.Percent.ToString(provider: CultureInfo.InvariantCulture) + "%",
        IsHigh: usage.Fraction >= ContextWarningFraction,
        Spoken: string.Create(
            provider: CultureInfo.InvariantCulture,
            handler: $"Context: {usage.Percent}% full ({Compact(value: usage.Tokens)} of {Compact(value: usage.Limit)} tokens)"));

    static string Scaled(double value, string suffix) =>
        (value >= 100 ? Math.Round(a: value) : Math.Round(value: value, digits: 1)).ToString(format: "0.#", provider: CultureInfo.InvariantCulture) + suffix;

    /// "↳ Release 2.5": the session that started it, which it opens when the Copilot app can.
    static RowTag Tag(RelatedSession parent, bool canOpen)
    {
        var startedBy = "Started by “" + parent.Name + "”";
        return new RowTag(
            Text: "↳ " + ShortName(name: parent.Name),
            ToolTip: canOpen ? startedBy + ": click to open it" : startedBy,
            Spoken: startedBy,
            Command: canOpen ? CopilotCommands.OpenParent : null);
    }

    /// The session that started it, unless that's where you answer its question, which the row names and opens already.
    static RelatedSession? OtherParent(SessionSnapshot session) =>
        session.Parent is { } parent && parent.Id != session.AnswerIn?.Id ? parent : null;

    /// What clicking it does first, then what its menu offers: none without the Copilot app, which opens sessions on
    /// Windows.
    static List<PanelCommand> Commands(SessionSnapshot session, bool canOpen, RelatedSession? otherParent)
    {
        if (!canOpen)
        {
            return [];
        }
        var commands = new List<PanelCommand>();
        if (session.AnswerIn is { } answerIn)
        {
            commands.Add(item: new PanelCommand(Key: CopilotCommands.Open, Title: "Answer in “" + answerIn.Name + "”", Opens: true));
            commands.Add(item: new PanelCommand(Key: CopilotCommands.OpenItself, Title: "Open this session", Opens: true));
        }
        else
        {
            commands.Add(item: new PanelCommand(Key: CopilotCommands.Open, Title: "Open in GitHub Copilot", Opens: true));
        }
        if (otherParent is not null)
        {
            commands.Add(item: new PanelCommand(Key: CopilotCommands.OpenParent, Title: "Open “" + otherParent.Name + "”", Opens: true));
        }
        return commands;
    }

    /// Everything its row shows, in full, and what clicking it does.
    static string ToolTip(SessionSnapshot session, bool canOpen, RelatedSession? otherParent, RowMeter? meter)
    {
        var lines = new List<string> { session.DisplayName, Subtitle(session: session) };
        if (session.Detail is { } detail)
        {
            lines.Add(item: detail);
        }
        if (session.Choices.Count > 0)
        {
            lines.Add(item: "Options: " + string.Join(separator: " | ", values: session.Choices));
        }
        if (meter is not null)
        {
            lines.Add(item: meter.Spoken);
        }
        if (otherParent is not null)
        {
            lines.Add(item: "Started by “" + otherParent.Name + "”");
        }
        if (session.AnswerIn is { } answerIn)
        {
            lines.Add(item: "“" + answerIn.Name + "”, which coordinates it, asks you this for it");
        }
        else if (session.AsksFor.Count > 0)
        {
            lines.Add(item: "Asks you for " + ListWords.Join(names: session.AsksFor.Select(selector: asked => "“" + asked.Name + "”").ToList()) + ", which it coordinates");
        }
        if (!canOpen)
        {
            lines.Add(item: "BriefBar opens sessions in the GitHub Copilot app, which isn't installed");
        }
        else if (session.AnswerIn is { } asking)
        {
            lines.Add(item: "Click to answer in “" + asking.Name + "”, or right-click to open this session");
        }
        else
        {
            lines.Add(item: "Click to open in GitHub Copilot");
        }
        return string.Join(separator: '\n', values: lines);
    }

    static SectionStatus Status(string? problem, bool hasSessions)
    {
        if (problem is null)
        {
            return SectionStatus.Live;
        }
        // With sessions to show, from the last good read or the session folders, it shows them, and says what's wrong.
        return new SectionStatus(
            Condition: hasSessions ? SectionCondition.Stale : SectionCondition.Problem, Problem: problem, ShortProblem: "Can't read");
    }
}
