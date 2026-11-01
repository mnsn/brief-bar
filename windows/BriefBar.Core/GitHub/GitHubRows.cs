using System.Globalization;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.GitHub;

/// What the GitHub pull requests' section shows, from its store: how it stands, its groups and rows, its brief, its
/// notices, who it reads as, and what its panel can do. The Mac's `GitHubSource` menu-bar parts, `MenuPanelView`,
/// `PRRowView` and `GroupStyle`, as data.
public static class GitHubRows
{
    /// Where the GitHub CLI's installation is explained.
    public static Uri InstallCliPage { get; } = new(uriString: "https://cli.github.com");

    /// Your open pull requests, on GitHub.
    public static Uri PullRequestsPage { get; } = new(uriString: "https://github.com/pulls");

    /// What the section shows as `store` stands.
    public static SectionSnapshot Snapshot(GitHubStore store)
    {
        ArgumentNullException.ThrowIfNull(argument: store);
        var problem = store.Problem;
        var items = store.Items;
        // Until you've signed in, nothing it lists is counted, nor in the brief: it may be someone else's.
        var counted = problem?.NeedsSignIn != true;
        var status = Status(problem: problem, starting: !store.HasLoaded, hasItems: items.Count > 0, refreshedAt: store.RefreshedAt);
        return new SectionSnapshot(
            Info: Sections.GitHubPullRequests,
            Status: status,
            Groups: [.. GitHubPRGroups.All.Select(selector: group => new RowGroup(Key: GroupKey(group: group), Title: group.Title(), State: group.State()))],
            Rows: [.. items.Select(selector: item => Row(item: item, counted: counted))],
            BriefLines: counted ? BriefLines(items: items) : [])
        {
            Commands = Commands(status: status),
            ProblemCommand = ProblemCommand(problem: problem),
            EmptyText = !store.HasLoaded && problem is null ? "Loading your pull requests…" : null,
            // Not when it couldn't read: the list may not be empty.
            Quiet = store.HasLoaded && items.Count == 0 && problem is null ? new QuietNote(Title: "All quiet", Detail: "No open pull requests for you") : null,
            Notices = Notices(store: store),
            Account = store.Login is { } login ? new SectionAccount(Name: login, Help: "Signed in to the GitHub CLI as " + login) : null,
        };
    }

    /// The key of `group` in the section's snapshot: the Mac's name for it.
    public static string GroupKey(GitHubPRGroup group) => group.RawValue();

    /// One pull request's row: why it's in its group, its title, what it's waiting for and who, which it is, when it last
    /// changed, and that pressing it opens it on GitHub. Not `counted`, it has no state, so that neither the bar nor the
    /// Overview counts it.
    public static ItemRow Row(GitHubPRSnapshot item, bool counted = true)
    {
        ArgumentNullException.ThrowIfNull(argument: item);
        return new ItemRow
        {
            Id = item.Id,
            Section = SectionId.GitHubPullRequests,
            Group = GroupKey(group: item.Group),
            State = counted ? item.Group.State() : null,
            Icon = Icon(reason: item.Reason),
            Title = item.PullRequest.Title,
            Status = Subtitle(item: item),
            Detail = item.PullRequest.Reference,
            Date = item.Since,
            Commands = [new PanelCommand(Key: GitHubCommands.Open, Title: "Open on GitHub", Opens: true)],
            ToolTip = string.Join(separator: '\n', values: [item.PullRequest.Title, item.PullRequest.Reference, Subtitle(item: item), "Click to open on GitHub"]),
        };
    }

    /// What it's waiting for, and who: "Review requested · By priya".
    public static string Subtitle(GitHubPRSnapshot item)
    {
        ArgumentNullException.ThrowIfNull(argument: item);
        return item.Detail is { } detail ? item.Headline + " · " + detail : item.Headline;
    }

    /// The icon of why it's where it is, as the Mac's SF Symbol for it.
    public static IconKey Icon(GitHubPRReason reason) => reason switch
    {
        GitHubPRReason.ReviewRequested => IconKey.Eye,
        GitHubPRReason.ChangesRequested => IconKey.ArrowReply,
        GitHubPRReason.ChecksFailed => IconKey.DismissCircle,
        GitHubPRReason.Conflicts => IconKey.Warning,
        GitHubPRReason.Approved => IconKey.CheckmarkCircle,
        GitHubPRReason.ChecksRunning => IconKey.HourglassHalf,
        GitHubPRReason.Draft => IconKey.Edit,
        GitHubPRReason.WaitingForReview => IconKey.Clock,
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(reason), actualValue: reason, message: "Not a reason."),
    };

    /// Each counted pull request in a sentence, in BriefBar's own words.
    static List<BriefLine> BriefLines(IReadOnlyList<GitHubPRSnapshot> items) => items
        .Where(predicate: item => item.Group.State() is not null)
        .Select(selector: item => new BriefLine(Id: item.Id, Section: SectionId.GitHubPullRequests, State: item.Group.State()!.Value, Date: item.Since, Sentence: item.BriefSentence))
        .ToList();

    /// The footer's: GitHub itself, and, once it has read, reading again now, an icon beside Settings, as Azure DevOps'
    /// is, for the Mac's Refresh Now.
    static List<PanelCommand> Commands(SectionStatus status)
    {
        var commands = new List<PanelCommand> { new(Key: GitHubCommands.OpenGitHub, Title: "Open GitHub", Help: "Your pull requests on GitHub", Opens: true) };
        if (status.Condition != SectionCondition.Starting)
        {
            commands.Add(item: new PanelCommand(Key: GitHubCommands.Refresh, Title: "Refresh", Help: "Refresh now")
            {
                Icon = IconKey.ArrowSync,
                IconOnly = true,
            });
        }
        return commands;
    }

    /// What GitHub couldn't read, and that there's more on GitHub than it reads.
    static List<SectionNotice> Notices(GitHubStore store)
    {
        var notices = new List<SectionNotice>();
        if (store.Notice is { } notice)
        {
            notices.Add(item: new SectionNotice(Message: notice));
        }
        if (store.MoreThanShown)
        {
            var count = PullRequestQuery.Count.ToString(provider: CultureInfo.InvariantCulture);
            notices.Add(item: new SectionNotice(Message: "There are more on GitHub: BriefBar shows your " + count + " most recently changed pull requests of each kind.")
            {
                Command = new PanelCommand(Key: GitHubCommands.MoreOnGitHub, Title: "More on GitHub", Help: "Your pull requests on GitHub", Opens: true),
            });
        }
        return notices;
    }

    /// How the section stands: what it can't read, and in a word or two for the bar, or when it last read.
    static SectionStatus Status(GitHubProblem? problem, bool starting, bool hasItems, DateTimeOffset? refreshedAt)
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
            GitHubProblemKind.CliNotFound => "Needs gh",
            GitHubProblemKind.SignedOut => "Sign in",
            GitHubProblemKind.AuthFailed => "Can't sign in",
            GitHubProblemKind.Offline => "Offline",
            GitHubProblemKind.Throttled => "Slowed down",
            _ => hasItems ? "Can't refresh" : "Can't read",
        };
        // Pull requests from the last good read stay, out of date, unless you need to sign in, when they're gone.
        var stale = hasItems && !problem.NeedsSignIn;
        return new SectionStatus(
            Condition: stale ? SectionCondition.Stale : SectionCondition.Problem, UpdatedAt: refreshedAt, Problem: problem.Message, ShortProblem: shortProblem);
    }

    /// What the banner offers for `problem`: signing in, installing the GitHub CLI, or trying again.
    static PanelCommand? ProblemCommand(GitHubProblem? problem) => problem?.Kind switch
    {
        null => null,
        GitHubProblemKind.CliNotFound => new PanelCommand(Key: GitHubCommands.InstallCli, Title: "Install the GitHub CLI…", Help: "How to install it, at cli.github.com", Opens: true),
        GitHubProblemKind.SignedOut => new PanelCommand(
            Key: GitHubCommands.SignIn, Title: "Sign in…", Help: "Runs gh auth login in a console window: it signs in through your browser", Opens: true),
        GitHubProblemKind.Throttled => null,
        _ => new PanelCommand(Key: GitHubCommands.Refresh, Title: "Try again"),
    };
}
