using System.Collections.ObjectModel;
using BriefBar.Core;
using BriefBar.Core.AzureDevOps;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;

namespace BriefBar.ViewModels;

/// Azure DevOps' own settings, on its page in Settings, as the Mac's gear menu and Settings page offer them: how often it
/// reads, how long Done and Idle wait, To review in the bar, the pipelines after your merges, your organizations and the
/// pull requests you watch. Each change is saved at once, and the list follows it. Its lists follow changes made
/// elsewhere too, such as your organizations once they're found, or a pull request you stopped watching in the panel, until
/// Settings closes (`Detach`). An organization you add is checked first, as on the Mac: whether your sign-in can read it,
/// and if not, why, which shows under the box. Made on the UI thread.
public sealed class AzureDevOpsSettingsViewModel : Observable
{
    readonly AzureDevOpsSettings settings;
    readonly Action findOrganizations;
    readonly Func<string, Action<OrganizationAccess?>, bool> addOrganization;
    readonly Action<string> signIn;
    readonly DispatcherQueue queue;
    /// The organizations you added whose latest check hasn't ended yet: by name, that add's number, as you may add one
    /// again meanwhile, which replaces the earlier check.
    readonly Dictionary<string, int> checking = new(comparer: StringComparer.OrdinalIgnoreCase);
    /// The directory the note under the box offers to sign in to.
    string? noteSignInTenant;
    int addsMade;
    int updateQueued;

    /// - `findOrganizations` asks Azure DevOps to look for your organizations again.
    /// - `addOrganization` asks Azure DevOps to check whether your sign-in can read an organization you add, and watch it
    ///   if it should, then hands what it found to its second argument, on any thread, once, or null when the check ended
    ///   without anything to act on; false when Azure DevOps isn't reading.
    /// - `signIn` signs in to the Azure CLI in a directory, an organization's.
    public AzureDevOpsSettingsViewModel(
        AzureDevOpsSettings settings, Action findOrganizations, Func<string, Action<OrganizationAccess?>, bool> addOrganization, Action<string> signIn)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: findOrganizations);
        ArgumentNullException.ThrowIfNull(argument: addOrganization);
        ArgumentNullException.ThrowIfNull(argument: signIn);
        this.settings = settings;
        this.findOrganizations = findOrganizations;
        this.addOrganization = addOrganization;
        this.signIn = signIn;
        queue = DispatcherQueue.GetForCurrentThread();
        settings.Changed += OnSettingsChanged;
        ShowLists();
    }

    public IReadOnlyList<string> RefreshTitles { get; } = AzureDevOpsSettings.RefreshChoices.Select(selector: AzureDevOpsSettings.RefreshTitle).ToList();

    /// Which of `RefreshTitles` is chosen.
    public int RefreshIndex
    {
        get => IndexOf(choices: AzureDevOpsSettings.RefreshChoices, value: settings.RefreshSeconds);
        set
        {
            if (value >= 0 && value < AzureDevOpsSettings.RefreshChoices.Count)
            {
                settings.RefreshSeconds = AzureDevOpsSettings.RefreshChoices[value];
            }
        }
    }

    public IReadOnlyList<string> KeepDoneTitles { get; } = AzureDevOpsSettings.KeepDoneChoices.Select(selector: AzureDevOpsSettings.KeepDoneTitle).ToList();

    public int KeepDoneIndex
    {
        get => IndexOf(choices: AzureDevOpsSettings.KeepDoneChoices, value: settings.KeepDoneHours);
        set
        {
            if (value >= 0 && value < AzureDevOpsSettings.KeepDoneChoices.Count)
            {
                settings.KeepDoneHours = AzureDevOpsSettings.KeepDoneChoices[value];
            }
        }
    }

    public IReadOnlyList<string> IdleTitles { get; } = AzureDevOpsSettings.IdleChoices.Select(selector: AzureDevOpsSettings.IdleTitle).ToList();

    public int IdleIndex
    {
        get => IndexOf(choices: AzureDevOpsSettings.IdleChoices, value: settings.IdleDays);
        set
        {
            if (value >= 0 && value < AzureDevOpsSettings.IdleChoices.Count)
            {
                settings.IdleDays = AzureDevOpsSettings.IdleChoices[value];
            }
        }
    }

    public bool ShowToReview
    {
        get => settings.ShowToReview;
        set => settings.ShowToReview = value;
    }

    public bool FollowMerges
    {
        get => settings.FollowMerges;
        set => settings.FollowMerges = value;
    }

    /// Your organizations, as last found, and the ones you added: each with whether it's watched.
    public ObservableCollection<OrganizationViewModel> Organizations { get; } = [];

    public bool HasNoOrganizations { get; private set => Set(storage: ref field, value: value); }

    /// What you typed to add an organization: its name, or a link from it.
    public string OrganizationInput { get; set => Set(storage: ref field, value: value); } = string.Empty;

    public string OrganizationError { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasOrganizationError { get; private set => Set(storage: ref field, value: value); }

    /// "Checking whether your sign-in can read contoso…", while an organization you added is checked.
    public string Checking { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool IsChecking { get; private set => Set(storage: ref field, value: value); }

    /// What a check found, when your sign-in can't read the organization you added: what's wrong, and what to do.
    public string NoteTitle { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public string NoteDetail { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// A warning for an organization that's watched all the same, as one in another directory; an error for one that isn't.
    public InfoBarSeverity NoteSeverity { get; private set => Set(storage: ref field, value: value); } = InfoBarSeverity.Warning;

    /// Whether the note shows: until you close it, or add another organization.
    public bool HasNote { get; set => Set(storage: ref field, value: value); }

    /// Whether the note offers to sign in, to the directory of an organization in another one.
    public bool NoteOffersSignIn { get; private set => Set(storage: ref field, value: value); }

    public ObservableCollection<WatchedPullRequestViewModel> Watched { get; } = [];

    public bool HasNoWatched { get; private set => Set(storage: ref field, value: value); }

    /// What you pasted to watch a pull request: its link.
    public string LinkInput { get; set => Set(storage: ref field, value: value); } = string.Empty;

    public string LinkError { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasLinkError { get; private set => Set(storage: ref field, value: value); }

    /// Watches the organization `OrganizationInput` names once Azure DevOps has checked that your sign-in can read it, or
    /// says why it can't. While Azure DevOps isn't reading, as for a moment while it starts or stops, it's watched without a
    /// check, as before: its list says what's wrong once it reads.
    public void AddOrganization()
    {
        if (OrganizationDiscovery.NameFrom(input: OrganizationInput) is not { } name)
        {
            ShowOrganizationError(error: "That isn't an organization's name. Names are letters, digits and hyphens, like the contoso in dev.azure.com/contoso.");
            return;
        }
        OrganizationInput = string.Empty;
        ShowOrganizationError(error: string.Empty);
        HasNote = false;
        if (settings.IsWatching(name: name))
        {
            return;
        }
        var add = ++addsMade;
        if (!addOrganization(arg1: name, arg2: access => queue.TryEnqueue(callback: () => ShowAccess(name: name, add: add, access: access))))
        {
            settings.ToggleOrganization(name: name);
            return;
        }
        checking[name] = add;
        ShowChecking();
    }

    /// Signs in to the directory of the organization the note is about.
    public void SignInFromNote()
    {
        if (noteSignInTenant is { } tenant)
        {
            signIn(obj: tenant);
        }
    }

    public void FindOrganizations() => findOrganizations();

    /// Watches the pull request `LinkInput` links to, or says why it can't.
    public void Watch()
    {
        var links = PullRequestLink.Find(text: LinkInput);
        if (links.Count == 0)
        {
            ShowLinkError(error: "That isn't a link to a pull request. Copy it from the pull request's page in Azure DevOps: it ends in /pullrequest/ and its number.");
            return;
        }
        settings.Watch(link: links[0]);
        LinkInput = string.Empty;
        ShowLinkError(error: string.Empty);
    }

    public void StopWatching(WatchedPullRequestViewModel pullRequest)
    {
        ArgumentNullException.ThrowIfNull(argument: pullRequest);
        settings.Unwatch(keys: new HashSet<PRKey> { pullRequest.Key });
    }

    /// Stops following the settings, as Settings closes.
    public void Detach() => settings.Changed -= OnSettingsChanged;

    static int IndexOf(IReadOnlyList<int> choices, int value)
    {
        for (var index = 0; index < choices.Count; index++)
        {
            if (choices[index] == value)
            {
                return index;
            }
        }
        return -1;
    }

    /// The settings changed, maybe on another thread: one update for a burst, on the UI thread.
    void OnSettingsChanged(object? sender, EventArgs e)
    {
        if (Interlocked.Exchange(location1: ref updateQueued, value: 1) == 1)
        {
            return;
        }
        if (!queue.TryEnqueue(callback: () =>
        {
            Volatile.Write(location: ref updateQueued, value: 0);
            ShowLists();
        }))
        {
            Volatile.Write(location: ref updateQueued, value: 0);
        }
    }

    /// Your organizations, and the pull requests you watch, as the settings say now.
    void ShowLists()
    {
        var names = OrganizationDiscovery.Merged(names: settings.Organizations, preferred: settings.KnownOrganizations);
        CollectionSync.Sync(
            items: Organizations,
            values: names,
            matches: (item, name) => string.Equals(a: item.Name, b: name, comparisonType: StringComparison.Ordinal),
            create: name => new OrganizationViewModel(name: name, isWatched: settings.IsWatching(name: name), toggle: settings.ToggleOrganization),
            update: (item, name) => item.Show(watched: settings.IsWatching(name: name)));
        HasNoOrganizations = names.Count == 0;
        var watched = settings.WatchedPullRequests;
        CollectionSync.Sync(
            items: Watched,
            values: watched,
            matches: (item, link) => item.Key == link.Key,
            create: link => new WatchedPullRequestViewModel(link: link),
            update: (_, _) => { });
        HasNoWatched = watched.Count == 0;
    }

    void ShowOrganizationError(string error)
    {
        OrganizationError = error;
        HasOrganizationError = error.Length > 0;
    }

    /// Which organizations you added are being checked, if any.
    void ShowChecking()
    {
        IsChecking = checking.Count > 0;
        Checking = IsChecking ? "Checking whether your sign-in can read " + ListWords.Join(names: [.. checking.Keys.Order(comparer: OrganizationDiscovery.NameOrder)]) + "…" : string.Empty;
    }

    /// The check that the add numbered `add` asked for of `name` ended, finding `access`: nothing to say when your sign-in
    /// reads it, or it couldn't be checked for now, as its list says what's wrong then, or the check ended without anything
    /// to act on (null), as when Azure DevOps stopped; otherwise what's wrong and what to do, with Sign in for an
    /// organization in another directory. An earlier add's check, which a later add of the same name replaced, says nothing
    /// whenever it ends: the later one does.
    void ShowAccess(string name, int add, OrganizationAccess? access)
    {
        if (!checking.TryGetValue(key: name, value: out var latest) || latest != add)
        {
            return;
        }
        checking.Remove(key: name);
        ShowChecking();
        if (access?.Explanation(organization: name) is not { } explanation)
        {
            return;
        }
        NoteTitle = explanation.Title;
        NoteDetail = explanation.Detail;
        NoteSeverity = access.Watches ? InfoBarSeverity.Warning : InfoBarSeverity.Error;
        noteSignInTenant = access.SignInTenant;
        NoteOffersSignIn = noteSignInTenant is not null;
        HasNote = true;
    }

    void ShowLinkError(string error)
    {
        LinkError = error;
        HasLinkError = error.Length > 0;
    }
}
