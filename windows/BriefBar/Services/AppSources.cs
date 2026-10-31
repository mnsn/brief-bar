using BriefBar.Core;
using BriefBar.Core.Copilot;
using BriefBar.Core.Demo;
using BriefBar.Core.Settings;

namespace BriefBar.Services;

/// BriefBar's sources, as you chose them: where your choices and their settings are saved, Copilot's settings, which
/// Settings changes too, and how each source is made. With --demo, every source is on, with made-up data, and nothing is
/// saved: choices last until BriefBar quits.
internal sealed class AppSources
{
    /// What the demo's Copilot app does: nothing, as made-up sessions open nothing.
    static readonly CopilotAppAccess demoApp = new(OpenSession: _ => { }, Activate: () => { }, IsInstalled: () => true, IsFrontmost: () => false);

    readonly bool isDemo;
    readonly DateTimeOffset madeAt;

    public AppSources(bool isDemo, DateTimeOffset madeAt)
    {
        this.isDemo = isDemo;
        this.madeAt = madeAt;
        Settings = isDemo ? DemoSettings(madeAt: madeAt) : new JsonFileSettings(path: JsonFileSettings.DefaultPath);
        Copilot = new CopilotSettings(settings: Settings, now: madeAt);
        Switch = new SourceSwitch(settings: Settings, entries: SourceCatalog.OnWindows, make: Make);
    }

    public ISettingsStorage Settings { get; }

    public CopilotSettings Copilot { get; }

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

    /// Where the Copilot app keeps its data, or where `BRIEFBAR_COPILOT_DIR` says.
    static Dictionary<string, string?> CopilotEnvironment() => new(comparer: StringComparer.Ordinal)
    {
        [CopilotPaths.DirectoryVariable] = Environment.GetEnvironmentVariable(variable: CopilotPaths.DirectoryVariable),
    };

    /// A source of `entry`, not started yet: the only one so far is Copilot's.
    CopilotSource Make(SourceEntry entry) => entry.Id switch
    {
        SourceId.Copilot => new CopilotSource(
            settings: Copilot,
            makeEngine: isDemo
                ? onChange => new DemoSessionEngine(madeAt: madeAt, onChange: onChange)
                : onChange => new SessionEngine(paths: CopilotPaths.Default(environment: CopilotEnvironment()), onChange: onChange),
            app: isDemo ? demoApp : CopilotAppShell.Access),
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(entry), actualValue: entry.Id, message: "Not a source BriefBar for Windows has."),
    };
}
