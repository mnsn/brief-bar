using System.Globalization;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.AzureDevOps;

/// What the Azure DevOps pull requests' section shows, from its store: how it stands, its groups and rows, its brief, and
/// what its panel can do. The Mac's `AzureDevOpsSource` menu-bar parts, `MenuPanelView`, `PRRowView` and `GroupStyle`, as
/// data.
public static class AzureDevOpsRows
{
    /// Where the Azure CLI's installation for Windows is explained.
    public static Uri InstallCliPage { get; } = new(uriString: "https://learn.microsoft.com/cli/azure/install-azure-cli-windows");

    /// What the section shows as `store` and `settings` stand at `now`.
    public static SectionSnapshot Snapshot(PRStore store, AzureDevOpsSettings settings, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: store);
        ArgumentNullException.ThrowIfNull(argument: settings);
        var showToReview = settings.ShowToReview;
        var items = store.Items;
        var placeholder = PlaceholderOf(store: store, settings: settings);
        // Without organizations, the engine's problem says only that: the placeholder says what to do.
        var problem = store.Problem?.Kind == PulseProblemKind.NoOrganizations ? null : store.Problem;
        // Until you've signed in, nothing it lists is counted, nor in the brief: it may be someone else's.
        var counted = problem?.NeedsSignIn != true;
        var status = Status(
            problem: problem, starting: placeholder is PRPlaceholder.Finding or PRPlaceholder.Loading, hasItems: items.Count > 0, refreshedAt: store.State.RefreshedAt);
        return new SectionSnapshot(
            Info: Sections.AzureDevOpsPullRequests,
            Status: status,
            Groups: Groups(items: items, showToReview: showToReview),
            Rows: items.Select(selector: item => Row(item: item, showToReview: showToReview, counted: counted)).ToList(),
            BriefLines: counted ? BriefLines(items: items, showToReview: showToReview) : [])
        {
            Commands = Commands(status: status, placeholder: placeholder),
            ProblemCommand = ProblemCommand(problem: problem),
            EmptyText = placeholder switch
            {
                PRPlaceholder.Finding => "Finding your Azure DevOps organizations… Once, the first time: BriefBar looks for the ones where you have pull requests.",
                PRPlaceholder.NoOrganizations => "No organizations to watch: none of yours has an active pull request of yours or for you to review.",
                PRPlaceholder.Loading => "Loading your pull requests…",
                _ => null,
            },
            Quiet = placeholder == PRPlaceholder.None && store.State.HasLoaded && store.Counts.Active == 0 && problem is null
                ? new QuietNote(Title: "All clear", Detail: IdleWords(idle: store.Counts[PRGroup.Idle]))
                : null,
        };
    }

    /// Under "All clear": "No open pull requests", "1 idle pull request", "3 idle pull requests".
    public static string IdleWords(int idle) => idle switch
    {
        0 => "No open pull requests",
        1 => "1 idle pull request",
        _ => idle.ToString(provider: CultureInfo.InvariantCulture) + " idle pull requests",
    };

    /// The key of `group` in the section's snapshot: the Mac's name for it.
    public static string GroupKey(PRGroup group) => group.RawValue();

    public static PRGroup? Group(string groupKey) => PRGroups.All.Cast<PRGroup?>().FirstOrDefault(predicate: group => group!.Value.RawValue() == groupKey);

    /// One pull request's row: its reason's icon, its title, where it stands and where, what it's about, and what clicking
    /// it does. Not `counted`, it has no state, so that neither the bar nor the Overview counts it.
    public static ItemRow Row(PRSnapshot item, bool showToReview, bool counted = true)
    {
        ArgumentNullException.ThrowIfNull(argument: item);
        var isNew = item.Group == PRGroup.NeedsYou && item.HasNews;
        return new ItemRow
        {
            Id = item.Id,
            Section = SectionId.AzureDevOpsPullRequests,
            Group = GroupKey(group: item.Group),
            State = counted ? item.Group.State(showToReview: showToReview) : null,
            Icon = Icon(reason: item.Reason),
            Title = item.Title,
            Status = Subtitle(item: item),
            Detail = item.Detail,
            Date = item.Since,
            IsNew = isNew,
            Commands = Commands(item: item),
            ToolTip = ToolTip(item: item, isNew: isNew),
        };
    }

    /// Where it stands, and where it is: "Sam Rivera replied · shop-web".
    public static string Subtitle(PRSnapshot item)
    {
        ArgumentNullException.ThrowIfNull(argument: item);
        return string.Join(separator: " · ", values: new[] { item.Headline, item.Repository }.Where(predicate: part => part.Length > 0));
    }

    /// The icon of why it's where it is, as the Mac's SF Symbol for it.
    public static IconKey Icon(PRReason reason) => reason switch
    {
        PRReason.Mentioned => IconKey.Mention,
        PRReason.SentInChat => IconKey.Send,
        PRReason.Replied => IconKey.ArrowReply,
        PRReason.Commented => IconKey.Comment,
        PRReason.ReviewRequested or PRReason.ReviewPending => IconKey.Eye,
        PRReason.NewCommits => IconKey.ArrowSync,
        PRReason.ChangesRequested => IconKey.ChatWarning,
        PRReason.Rejected => IconKey.ThumbDislike,
        PRReason.Answered => IconKey.CommentCheckmark,
        PRReason.BuildFailed => IconKey.DismissCircle,
        PRReason.CheckFailed => IconKey.ErrorCircle,
        PRReason.Conflicts => IconKey.BranchCompare,
        PRReason.BuildExpired => IconKey.ClockDismiss,
        PRReason.FailedAfterMerge or PRReason.Completed => IconKey.Merge,
        PRReason.ReadyToComplete => IconKey.CheckmarkCircle,
        PRReason.AutoComplete => IconKey.CheckmarkStarburst,
        PRReason.WaitingForReviewers => IconKey.People,
        PRReason.ChecksRunning => IconKey.HourglassHalf,
        PRReason.RequirementsPending => IconKey.ClipboardTaskList,
        PRReason.WaitingForAuthor => IconKey.Clock,
        PRReason.WaitingForApproval => IconKey.HandRaise,
        PRReason.Abandoned => IconKey.Delete,
        PRReason.Draft => IconKey.Edit,
        PRReason.Inactive => IconKey.WeatherMoon,
        PRReason.YouApproved => IconKey.Checkmark,
        PRReason.Declined => IconKey.PersonDelete,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(reason), actualValue: reason, message: "Not a reason."),
    };

    /// What the panel says in place of the list while it's empty, as the Mac does: it's finding your organizations, you
    /// have none to watch, or it's reading them for the first time, or those just chosen.
    static PRPlaceholder PlaceholderOf(PRStore store, AzureDevOpsSettings settings)
    {
        if (store.Items.Count > 0)
        {
            return PRPlaceholder.None;
        }
        var organizations = settings.Organizations;
        if (organizations.Count == 0)
        {
            if (store.Discovery == PRDiscovery.Running || (!settings.HasDiscovered && store.Problem is null))
            {
                return PRPlaceholder.Finding;
            }
            return settings.HasDiscovered ? PRPlaceholder.NoOrganizations : PRPlaceholder.None;
        }
        // Until each organization has been read once, an empty list isn't all clear: as the Mac says while it refreshes,
        // but only the first time, so that the bar doesn't say it's starting at every refresh.
        var state = store.State;
        var reading = !state.HasLoaded
            || !state.Organizations.SequenceEqual(second: organizations, comparer: StringComparer.Ordinal)
            || organizations.Any(predicate: organization => state.FirstRead(organization: organization) is null);
        return reading && store.Problem is null ? PRPlaceholder.Loading : PRPlaceholder.None;
    }

    /// Each counted pull request in a sentence, as Azure DevOps' own brief says it.
    static List<BriefLine> BriefLines(IReadOnlyList<PRSnapshot> items, bool showToReview) => items
        .Select(selector: item => (Item: item, State: item.Group.State(showToReview: showToReview)))
        .Where(predicate: pair => pair.State is not null)
        .Select(selector: pair => new BriefLine(
            Id: pair.Item.Id, Section: SectionId.AzureDevOpsPullRequests, State: pair.State!.Value, Date: pair.Item.Since, Sentence: Brief.Item(snapshot: pair.Item).Sentence))
        .ToList();

    /// The footer's: choosing organizations, without any; Azure DevOps itself; and, once it has started, reading again
    /// now, an icon beside Settings, as the Mac's is.
    static List<PanelCommand> Commands(SectionStatus status, PRPlaceholder placeholder)
    {
        var commands = new List<PanelCommand>();
        if (placeholder == PRPlaceholder.NoOrganizations)
        {
            commands.Add(item: new PanelCommand(Key: AppCommands.ReviewSource, Title: "Choose organizations…", Help: "Choose them in Azure DevOps' settings", Opens: true)
            {
                Icon = IconKey.Settings,
            });
        }
        commands.Add(item: new PanelCommand(Key: AzureDevOpsCommands.OpenAzureDevOps, Title: "Open Azure DevOps", Help: "Your pull requests in Azure DevOps", Opens: true));
        if (status.Condition != SectionCondition.Starting)
        {
            commands.Add(item: new PanelCommand(Key: AzureDevOpsCommands.Refresh, Title: "Refresh", Help: "Refresh now")
            {
                Icon = IconKey.ArrowSync,
                IconOnly = true,
            });
        }
        return commands;
    }

    /// Each group, in the list's order, the bar's state for those it counts: Needs you's Mark as seen while something there
    /// is new, Done's Clear, and Idle folded, as on the Mac.
    static List<RowGroup> Groups(IReadOnlyList<PRSnapshot> items, bool showToReview) => PRGroups.All.Select(selector: group => new RowGroup(
        Key: GroupKey(group: group), Title: group.Title(), State: group.State(showToReview: showToReview))
    {
        Commands = group switch
        {
            PRGroup.NeedsYou when items.Any(predicate: item => item.Group == PRGroup.NeedsYou && item.HasNews) =>
                [new PanelCommand(Key: AzureDevOpsCommands.MarkAsSeen, Title: "Mark as seen", Help: "You've seen these: what's new moves on, and comments that wait on you stay until you reply, they're resolved, or you remove them")],
            PRGroup.Done => [new PanelCommand(Key: AzureDevOpsCommands.Clear, Title: "Clear", Help: "Remove these from the list")],
            _ => [],
        },
        IsFolded = group == PRGroup.Idle,
    }).ToList();

    /// Opening it first, then what its menu offers.
    static List<PanelCommand> Commands(PRSnapshot item)
    {
        var commands = new List<PanelCommand> { new(Key: AzureDevOpsCommands.Open, Title: "Open in Azure DevOps", Opens: true) };
        if (item.Group == PRGroup.NeedsYou)
        {
            commands.Add(item: new PanelCommand(
                Key: AzureDevOpsCommands.RemoveFromNeedsYou, Title: "Remove from Needs you", Help: "What waits on you here doesn't anymore; anything new needs you again"));
        }
        if (item.IsWatched)
        {
            commands.Add(item: new PanelCommand(Key: AzureDevOpsCommands.StopWatching, Title: "Stop watching"));
        }
        return commands;
    }

    /// Everything its row shows, in full, and what clicking and its menu do.
    static string ToolTip(PRSnapshot item, bool isNew)
    {
        var lines = new List<string>
        {
            item.Title,
            item.Repository + " · " + item.Project + " · !" + item.Key.Number.ToString(provider: CultureInfo.InvariantCulture) + " by " + item.Author,
            item.Headline,
        };
        if (item.Detail is { } detail)
        {
            lines.Add(item: detail);
        }
        if (item.Approvals.Count > 0 && item.Group != PRGroup.Ready)
        {
            lines.Add(item: "Approved by " + string.Join(separator: ", ", values: item.Approvals));
        }
        if (item.Group == PRGroup.NeedsYou && !isNew)
        {
            lines.Add(item: "You've seen it: it stays here until you reply, the comments are resolved, or you remove it");
        }
        lines.Add(item: "Click to open in Azure DevOps");
        if (item.Group == PRGroup.NeedsYou)
        {
            lines.Add(item: "Right-click to remove it from Needs you");
        }
        if (item.IsWatched)
        {
            lines.Add(item: "You watch it: right-click to stop");
        }
        return string.Join(separator: '\n', values: lines);
    }

    /// How the section stands: what it can't read, and in a word or two for the bar, or when it last read.
    static SectionStatus Status(PulseProblem? problem, bool starting, bool hasItems, DateTimeOffset? refreshedAt)
    {
        if (problem is null)
        {
            if (starting)
            {
                return SectionStatus.Starting;
            }
            return refreshedAt is { } time ? SectionStatus.Updated(time: time) : new SectionStatus(Condition: SectionCondition.Ready);
        }
        var shortProblem = problem.Kind switch
        {
            PulseProblemKind.CliNotFound => "Needs az",
            PulseProblemKind.SignedOut => "Sign in",
            PulseProblemKind.AuthFailed => "Can't sign in",
            PulseProblemKind.Offline => "Offline",
            PulseProblemKind.Throttled => "Slowed down",
            _ => hasItems ? "Can't refresh" : "Can't read",
        };
        // Pull requests from the last good read stay, out of date, unless you need to sign in, when they may not be yours.
        var stale = hasItems && !problem.NeedsSignIn;
        return new SectionStatus(
            Condition: stale ? SectionCondition.Stale : SectionCondition.Problem, UpdatedAt: refreshedAt, Problem: problem.Message, ShortProblem: shortProblem);
    }

    /// What the banner offers for `problem`: signing in, installing the Azure CLI, or trying again.
    static PanelCommand? ProblemCommand(PulseProblem? problem) => problem?.Kind switch
    {
        null => null,
        PulseProblemKind.CliNotFound => new PanelCommand(Key: AzureDevOpsCommands.InstallCli, Title: "Install the Azure CLI…", Help: "How to install it, at Microsoft Learn", Opens: true),
        PulseProblemKind.SignedOut => new PanelCommand(
            Key: AzureDevOpsCommands.SignIn, Title: "Sign in…", Help: "Runs az login in a console window: it opens your browser, or Windows' sign-in", Opens: true),
        PulseProblemKind.Throttled => null,
        _ => new PanelCommand(Key: AzureDevOpsCommands.Refresh, Title: "Try again"),
    };
}
