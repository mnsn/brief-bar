using System.Globalization;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.AzureDevOps;

/// What the Azure DevOps pull requests' section shows, from its store: how it stands, its groups and rows, its brief, and
/// what its panel can do. The Mac's `AzureDevOpsSource` menu-bar parts, `MenuPanelView`, `PRRowView` and `GroupStyle`, as
/// data.
public static class AzureDevOpsRows
{
    /// The key of the one group a list by date has, before Done's and Idle's.
    public const string DateListKey = "byDate";

    /// Where the Azure CLI's installation for Windows is explained.
    public static Uri InstallCliPage { get; } = new(uriString: "https://learn.microsoft.com/cli/azure/install-azure-cli-windows");

    /// What the section shows as `store` and `settings` stand at `now`: its groups and rows in the order you chose, by
    /// status or by when each was created (`AzureDevOpsSettings.PullRequestOrder`). Counts and the brief stay by status.
    public static SectionSnapshot Snapshot(PRStore store, AzureDevOpsSettings settings, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: store);
        ArgumentNullException.ThrowIfNull(argument: settings);
        var showToReview = settings.ShowToReview;
        var order = settings.PullRequestOrder;
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
            Groups: order.IsByDate() ? DateGroups(store: store, order: order, showToReview: showToReview) : Groups(items: items, showToReview: showToReview),
            Rows: Rows(store: store, order: order, showToReview: showToReview, counted: counted, now: now),
            BriefLines: counted ? BriefLines(items: items, showToReview: showToReview) : [])
        {
            Commands = Commands(status: status, placeholder: placeholder),
            ProblemCommand = ProblemCommand(problem: problem),
            ProblemHint = ProblemHint(problem: problem),
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
            Sort = SortMenu(order: order),
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

    /// One pull request's row: its reason's icon, its title, where it stands and where, what it's about, what's left before
    /// you can complete it, for your own, and what clicking it does. Not `counted`, it has no state, so that neither the
    /// bar nor the Overview counts it.
    public static ItemRow Row(PRSnapshot item, bool showToReview, DateTimeOffset now, bool counted = true)
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
            ToolTip = ToolTip(item: item, isNew: isNew, now: now),
            Checklist = item.Readiness is { Items.Count: > 0 } readiness ? Checklist(readiness: readiness, isQuiet: item.Group == PRGroup.Idle) : null,
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
        PRReason.MergeFailed => IconKey.Warning,
        PRReason.BuildExpired => IconKey.ClockDismiss,
        PRReason.FailedAfterMerge or PRReason.Completed => IconKey.Merge,
        PRReason.ReadyToComplete => IconKey.CheckmarkCircle,
        PRReason.AutoComplete => IconKey.CheckmarkStarburst,
        PRReason.WaitingForReviewers => IconKey.PeopleFilled,
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

    /// The icon of where one thing that's left before you can complete a pull request stands, as a pipeline's run shows
    /// it: done, failing, waiting on you, running, and a clock while it waits on someone else; open comments that don't
    /// hold the pull request up, a speech bubble.
    public static IconKey Icon(PRReadinessItem item)
    {
        ArgumentNullException.ThrowIfNull(argument: item);
        if (!item.IsRequired)
        {
            return IconKey.Comment;
        }
        return item.State switch
        {
            ItemState.Done => IconKey.CheckmarkCircle,
            ItemState.Failing => IconKey.DismissCircle,
            ItemState.NeedsYou => IconKey.HandRaise,
            ItemState.Running => IconKey.ArrowSync,
            null => IconKey.Clock,
            _ => throw new ArgumentOutOfRangeException(paramName: nameof(item), actualValue: item.State, message: "Not a state."),
        };
    }

    /// What's left and what's done, a line each, for a row's tooltip and Narrator: "Left to complete it: 1 of 2 approvals
    /// (Approved by Priya Shah); Resolve 1 comment", "Done: Build passed (payments-api CI)".
    public static IReadOnlyList<string> ReadinessLines(PRReadiness readiness)
    {
        ArgumentNullException.ThrowIfNull(argument: readiness);
        var blocking = readiness.Items.Where(predicate: item => item.IsRequired && !item.IsDone).ToList();
        var optional = readiness.Items.Where(predicate: item => !item.IsRequired && !item.IsDone).ToList();
        var done = readiness.Items.Where(predicate: item => item.IsDone).ToList();
        var lines = new List<string>
        {
            blocking.Count == 0
                ? "Nothing left to complete it" + (readiness.IsCurrent ? string.Empty : ", as last read")
                : "Left to complete it: " + Described(items: blocking),
        };
        if (optional.Count > 0)
        {
            lines.Add(item: "Not required: " + Described(items: optional));
        }
        if (done.Count > 0)
        {
            lines.Add(item: "Done: " + Described(items: done));
        }
        if (!readiness.IsCurrent)
        {
            lines.Add(item: "It changed since its policies were read: they're read again at the next refresh");
        }
        return lines;
    }

    /// Whether a row's tooltip would say how long ago its pull request was created differently at `now` than at `then`,
    /// when it was built: "Created 5m ago" moves on, as the Mac's does.
    public static bool CreatedWordsChanged(IEnumerable<PRSnapshot> items, DateTimeOffset then, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(argument: items);
        return items.Any(predicate: item => item.CreatedAt is { } created && CreatedWords(created: created, now: then) != CreatedWords(created: created, now: now));
    }

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
    static List<RowGroup> Groups(IReadOnlyList<PRSnapshot> items, bool showToReview) =>
        [.. PRGroups.All.Select(selector: group => StatusGroup(group: group, items: items, showToReview: showToReview))];

    /// A list by date's groups: every pull request but Done's and Idle's in one, with Mark as seen while something new
    /// there needs you; then Done's and Idle's, as they are by status.
    static List<RowGroup> DateGroups(PRStore store, PROrder order, bool showToReview)
    {
        var listed = store.DateList(order: order);
        var byDate = new RowGroup(Key: DateListKey, Title: order.Title(), State: null)
        {
            Commands = listed.Any(predicate: item => item.Group == PRGroup.NeedsYou && item.HasNews) ? [MarkAsSeen()] : [],
        };
        return [byDate, .. new[] { PRGroup.Done, PRGroup.Idle }.Select(selector: group => StatusGroup(group: group, items: store.Items, showToReview: showToReview))];
    }

    static RowGroup StatusGroup(PRGroup group, IReadOnlyList<PRSnapshot> items, bool showToReview) =>
        new(Key: GroupKey(group: group), Title: group.Title(), State: group.State(showToReview: showToReview))
        {
            Commands = group switch
            {
                PRGroup.NeedsYou when items.Any(predicate: item => item.Group == PRGroup.NeedsYou && item.HasNews) => [MarkAsSeen()],
                PRGroup.Done => [new PanelCommand(Key: AzureDevOpsCommands.Clear, Title: "Clear", Help: "Remove these from the list")],
                _ => [],
            },
            IsFolded = group == PRGroup.Idle,
        };

    static PanelCommand MarkAsSeen() => new(
        Key: AzureDevOpsCommands.MarkAsSeen,
        Title: "Mark as seen",
        Help: "You've seen these: what's new moves on, and comments that wait on you stay until you reply, they're resolved, or you remove them");

    /// The rows in the order you chose. By status, in their groups. By date, every pull request but Done's and Idle's in
    /// one list, by when each was created, each still saying where it stands, and its time how long ago it was created;
    /// then Done's, the latest first, as by status; then Idle's, in the same order as the list.
    static List<ItemRow> Rows(PRStore store, PROrder order, bool showToReview, bool counted, DateTimeOffset now)
    {
        ItemRow RowOf(PRSnapshot item) => Row(item: item, showToReview: showToReview, now: now, counted: counted);
        if (!order.IsByDate())
        {
            return [.. store.Items.Select(selector: RowOf)];
        }
        var byDate = store.ItemsBy(order: order);
        var listed = store.DateList(order: order).Select(selector: item => RowOf(item: item) with { Group = DateListKey, Created = item.CreatedAt });
        var done = store.Items.Where(predicate: item => item.Group == PRGroup.Done).Select(selector: RowOf);
        var idle = byDate.Where(predicate: item => item.Group == PRGroup.Idle).Select(selector: item => RowOf(item: item) with { Created = item.CreatedAt });
        return [.. listed, .. done, .. idle];
    }

    /// What's left before you can complete it, and what's done, on a line under its row; its words quiet, as an idle row's.
    static RowChecklist Checklist(PRReadiness readiness, bool isQuiet) => new(
        Items: new ValueList<RowChecklistItem>(items: readiness.Items.Select(selector: item => new RowChecklistItem(
            Icon: Icon(item: item), State: item.IsRequired ? item.State : null, Label: item.Label, IsDone: item.IsDone))),
        Summary: new ValueList<string>(items: ReadinessLines(readiness: readiness)),
        IsQuiet: isQuiet);

    /// "Build failed (shop-web CI · Run unit tests: 2 tests failed); Resolve 1 comment".
    static string Described(IEnumerable<PRReadinessItem> items) =>
        string.Join(separator: "; ", values: items.Select(selector: item => string.IsNullOrEmpty(value: item.Detail) ? item.Label : item.Label + " (" + item.Detail + ")"));

    /// The menu at the top of the list that sorts it: by status, or by when each was created.
    static SectionSort SortMenu(PROrder order) => new(
        Choices: new ValueList<PanelCommand>(items: PROrders.All.Select(selector: choice => new PanelCommand(Key: AzureDevOpsCommands.Sort(order: choice), Title: choice.Title()))),
        Chosen: AzureDevOpsCommands.Sort(order: order),
        Name: "Sort pull requests",
        Help: "Sort: " + order.Title() + ". By status groups them by what they need from you; Newest first and Oldest first list them by when each was created");

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

    /// Everything its row shows, in full, what's left before you can complete it, when it was created, and what clicking
    /// and its menu do.
    static string ToolTip(PRSnapshot item, bool isNew, DateTimeOffset now)
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
        // What's left says who approved, for your own.
        if (item.Approvals.Count > 0 && item.Group != PRGroup.Ready && item.Readiness is null)
        {
            lines.Add(item: "Approved by " + string.Join(separator: ", ", values: item.Approvals));
        }
        if (item.Readiness is { Items.Count: > 0 } readiness)
        {
            lines.AddRange(collection: ReadinessLines(readiness: readiness));
        }
        if (item.CreatedAt is { } created)
        {
            lines.Add(item: CreatedWords(created: created, now: now));
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

    /// "Created 2d ago", "Created 1h 5m ago", "Created just now".
    static string CreatedWords(DateTimeOffset created, DateTimeOffset now)
    {
        var elapsed = Elapsed.Compact(since: created, now: now);
        return elapsed == "now" ? "Created just now" : "Created " + elapsed + " ago";
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
            // Nothing else is listed: signing in to their directory is what reads them.
            PulseProblemKind.OtherDirectory => "Sign in",
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

    /// What the banner offers for `problem`: signing in, in the directory to sign in to when there's one, installing the
    /// Azure CLI, or trying again.
    static PanelCommand? ProblemCommand(PulseProblem? problem) => problem switch
    {
        null => null,
        { Kind: PulseProblemKind.CliNotFound } => new PanelCommand(Key: AzureDevOpsCommands.InstallCli, Title: "Install the Azure CLI…", Help: "How to install it, at Microsoft Learn", Opens: true),
        { SignInTenant: { } tenant } => new PanelCommand(
            Key: AzureDevOpsCommands.SignInTo(tenant: tenant),
            Title: "Sign in…",
            Help: "Runs az login in a console window, in the directory it needs: it opens your browser, or Windows' sign-in",
            Opens: true),
        { Kind: PulseProblemKind.SignedOut } => new PanelCommand(
            Key: AzureDevOpsCommands.SignIn, Title: "Sign in…", Help: "Runs az login in a console window: it opens your browser, or Windows' sign-in", Opens: true),
        { Kind: PulseProblemKind.Throttled } => null,
        _ => new PanelCommand(Key: AzureDevOpsCommands.Refresh, Title: "Try again"),
    };

    /// What the banner adds after `problem`, in the panel only: for organizations in a directory the Azure CLI isn't signed
    /// in to, what Sign in does, and what to do if one is a project's name rather than an organization's, as the Mac's
    /// `ProblemView` says it.
    static string? ProblemHint(PulseProblem? problem) => problem is { Kind: PulseProblemKind.OtherDirectory, Organizations: { } organizations }
        ? "Sign in runs az login there, in a console window. If " + (organizations.Count == 1 ? "it's" : "one is")
            + " a project rather than an organization, remove it in Settings: a project's organization is the first part of its link."
        : null;
}
