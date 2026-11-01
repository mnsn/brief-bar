using System.Collections.ObjectModel;
using BriefBar.Core.AzureDevOps;
using Microsoft.UI.Dispatching;

namespace BriefBar.ViewModels;

/// Azure DevOps' own settings, on its page in Settings, as the Mac's gear menu and Settings page offer them: how often it
/// reads, how long Done and Idle wait, To review in the bar, the pipelines after your merges, your organizations and the
/// pull requests you watch. Each change is saved at once, and the list follows it. Its lists follow changes made
/// elsewhere too, such as your organizations once they're found, or a pull request you stopped watching in the panel, until
/// Settings closes (`Detach`). Made on the UI thread.
public sealed class AzureDevOpsSettingsViewModel : Observable
{
    readonly AzureDevOpsSettings settings;
    readonly Action findOrganizations;
    readonly DispatcherQueue queue;
    int updateQueued;

    /// `findOrganizations` asks Azure DevOps to look for your organizations again.
    public AzureDevOpsSettingsViewModel(AzureDevOpsSettings settings, Action findOrganizations)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: findOrganizations);
        this.settings = settings;
        this.findOrganizations = findOrganizations;
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

    public ObservableCollection<WatchedPullRequestViewModel> Watched { get; } = [];

    public bool HasNoWatched { get; private set => Set(storage: ref field, value: value); }

    /// What you pasted to watch a pull request: its link.
    public string LinkInput { get; set => Set(storage: ref field, value: value); } = string.Empty;

    public string LinkError { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasLinkError { get; private set => Set(storage: ref field, value: value); }

    /// Watches the organization `OrganizationInput` names, or says why it can't.
    public void AddOrganization()
    {
        if (OrganizationDiscovery.NameFrom(input: OrganizationInput) is not { } name)
        {
            ShowOrganizationError(error: "That isn't an organization's name. Names are letters, digits and hyphens, like the contoso in dev.azure.com/contoso.");
            return;
        }
        if (!settings.IsWatching(name: name))
        {
            settings.ToggleOrganization(name: name);
        }
        OrganizationInput = string.Empty;
        ShowOrganizationError(error: string.Empty);
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

    void ShowLinkError(string error)
    {
        LinkError = error;
        HasLinkError = error.Length > 0;
    }
}
