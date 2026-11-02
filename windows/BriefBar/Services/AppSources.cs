using BriefBar.Core;
using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Copilot;
using BriefBar.Core.Demo;
using BriefBar.Core.GitHub;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;
using Microsoft.UI.Dispatching;

namespace BriefBar.Services;

/// BriefBar's sources, as you chose them: where your choices and their settings are saved, each source's settings, which
/// Settings changes too, and how each source is made. With --demo, every source is on, with made-up data, and nothing is
/// saved: choices last until BriefBar quits.
internal sealed class AppSources
{
    /// What the demo's Copilot app does: nothing, as made-up sessions open nothing.
    static readonly CopilotAppAccess demoApp = new(OpenSession: _ => { }, Activate: () => { }, IsInstalled: () => true, IsFrontmost: () => false);

    /// What the demo's Azure DevOps opens: nothing, as made-up pull requests aren't anywhere.
    static readonly AzureDevOpsAccess demoAzureDevOps = new(OpenLink: _ => { });

    /// What the demo's GitHub opens: nothing, as made-up pull requests aren't anywhere.
    static readonly GitHubAccess demoGitHub = new(OpenLink: _ => { });

    static readonly ProcessRunner processes = new();

    readonly bool isDemo;
    readonly DateTimeOffset madeAt;
    readonly DispatcherQueue queue;

    /// `queue` runs the UI thread, where a source's windows and dialogs show.
    public AppSources(bool isDemo, DateTimeOffset madeAt, DispatcherQueue queue)
    {
        this.isDemo = isDemo;
        this.madeAt = madeAt;
        this.queue = queue;
        Settings = isDemo ? DemoSettings(madeAt: madeAt) : new JsonFileSettings(path: JsonFileSettings.DefaultPath);
        AzureDevOps = isDemo
            ? AzureDevOpsDemoData.Settings(storage: Settings, now: madeAt)
            : new AzureDevOpsSettings(settings: Settings, now: madeAt);
        Copilot = new CopilotSettings(settings: Settings, now: madeAt);
        GitHub = new GitHubSettings(settings: Settings);
        Appearance = new AppearanceSettings(settings: Settings);
        Switch = new SourceSwitch(settings: Settings, entries: SourceCatalog.OnWindows, make: Make);
    }

    public ISettingsStorage Settings { get; }

    public AzureDevOpsSettings AzureDevOps { get; }

    public CopilotSettings Copilot { get; }

    public GitHubSettings GitHub { get; }

    /// What the bar shows behind its words, as chosen in Settings.
    public AppearanceSettings Appearance { get; }

    public SourceSwitch Switch { get; }

    /// The sources to run as BriefBar starts: those you turned on, and, with --demo, made-up ones for the sources that
    /// Windows doesn't have yet.
    public IReadOnlyList<ISectionSource> Initial() => isDemo
        ? [.. Switch.Initial(), .. DemoSource.All(madeAt: madeAt).Where(predicate: source => !SourceCatalog.OnWindows.Any(predicate: entry => entry.Id == source.Source))]
        : Switch.Initial();

    /// Settings for the demo, in memory, with every source on.
    static MemorySettings DemoSettings(DateTimeOffset madeAt)
    {
        var settings = new MemorySettings();
        var choices = new SourceChoices();
        foreach (var entry in SourceCatalog.OnWindows)
        {
            choices.TurnOn(source: entry.Id, version: entry.Description.Version, date: madeAt);
        }
        choices.Save(settings: settings);
        return settings;
    }

    /// BriefBar's environment's `names`, as a locator or a folder's default reads them: where the Copilot app keeps its
    /// data, or where `BRIEFBAR_COPILOT_DIR` says; where the Azure CLI, the GitHub CLI or the Copilot CLI may be.
    static Dictionary<string, string?> EnvironmentOf(IReadOnlyList<string> names) => names.ToDictionary(
        keySelector: name => name, elementSelector: name => Environment.GetEnvironmentVariable(variable: name), comparer: StringComparer.OrdinalIgnoreCase);

    /// Azure DevOps itself, with the Azure CLI's sign-in.
    static AzureDevOpsReading LiveAzureDevOps()
    {
        var locator = new AzureCLILocator(environment: EnvironmentOf(names: AzureCLILocator.Variables));
        return AzureDevOpsReading.Live(tokens: new AzureCLITokenProvider(locator: locator, runner: processes), locator: locator);
    }

    /// GitHub itself, with the GitHub CLI's sign-in.
    static GitHubReading LiveGitHub()
    {
        var locator = new GitHubCLILocator(environment: EnvironmentOf(names: GitHubCLILocator.Variables));
        return GitHubReading.Live(tokens: new GitHubCLITokenProvider(locator: locator, runner: processes), locator: locator);
    }

    /// A source of `entry`, not started yet.
    ISectionSource Make(SourceEntry entry) => entry.Id switch
    {
        SourceId.AzureDevOps => new AzureDevOpsSource(
            settings: AzureDevOps,
            reading: isDemo ? DemoAzureDevOps() : LiveAzureDevOps(),
            access: isDemo ? demoAzureDevOps : new AzureDevOpsAccess(OpenLink: link => BrowserShell.Open(link: link, source: SourceId.AzureDevOps)),
            processes: processes),
        SourceId.Copilot => isDemo
            ? new CopilotSource(settings: Copilot, makeEngine: onChange => new DemoSessionEngine(madeAt: madeAt, onChange: onChange), app: demoApp)
            : LiveCopilot(),
        SourceId.GitHub => new GitHubSource(
            settings: GitHub,
            reading: isDemo ? DemoGitHub() : LiveGitHub(),
            access: isDemo ? demoGitHub : new GitHubAccess(OpenLink: link => BrowserShell.Open(link: link, source: SourceId.GitHub)),
            processes: processes),
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(entry), actualValue: entry.Id, message: "Not a source BriefBar for Windows has."),
    };

    /// The Copilot app's sessions, in its folder, or where `BRIEFBAR_COPILOT_DIR` says; on a PC without the app, they open
    /// in a terminal with the Copilot CLI.
    CopilotSource LiveCopilot()
    {
        var paths = CopilotPaths.Default(environment: EnvironmentOf(names: [CopilotPaths.DirectoryVariable]));
        return new CopilotSource(
            settings: Copilot,
            makeEngine: onChange => new SessionEngine(paths: paths, onChange: onChange),
            app: CopilotAppShell.Access,
            cliSessions: new CLISession(
                paths: paths,
                locator: new CopilotCLILocator(environment: EnvironmentOf(names: CopilotCLILocator.Variables)),
                processes: processes,
                shell: CopilotCLIShell.Make(queue: queue)));
    }

    /// The demo's made-up pull requests, in its one made-up organization, without the Azure CLI.
    AzureDevOpsReading DemoAzureDevOps() => new(
        makeEngine: onChange => new DemoPulseEngine(madeAt: madeAt, onChange: onChange),
        findOrganizations: _ => Task.FromResult(result: new OrganizationsFound(All: [AzureDevOpsDemoData.Organization], WithPullRequests: [AzureDevOpsDemoData.Organization])),
        locateCli: () => null);

    /// The demo's made-up pull requests on GitHub, read again as often as GitHub's would be, without the GitHub CLI.
    GitHubReading DemoGitHub() => new(load: _ => Task.FromResult(result: GitHubDemoData.Load(now: madeAt)), locateCli: () => null);
}
