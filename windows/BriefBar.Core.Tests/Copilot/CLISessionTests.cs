using System.ComponentModel;
using BriefBar.Core.Copilot;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Tests.Copilot;

/// Opening a session on a PC without the GitHub Copilot app, as the Mac's `CLISessionTests`: the terminal of a CLI that
/// has it open comes up; any other goes on in a new terminal with `copilot --resume`, in its folder, once at a time; and
/// what goes wrong is said. With made-up sessions, a made-up CLI, and nothing started.
public sealed class CLISessionTests
{
    /// A made-up session's ID, as the app writes it, and as the panel might pass it.
    const string Id = "6f1c1a52-0000-4000-8000-00000000d001";
    const string Cli = @"C:\Tools\copilot.exe";

    [Fact]
    public async Task OpensASessionNoCliHoldsInANewTerminal()
    {
        using var setup = new Setup();
        var opening = setup.Session.Open(id: Id.ToUpperInvariant());
        Assert.NotNull(@object: opening);
        await opening.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        var console = Assert.Single(collection: setup.Processes.Consoles);
        Assert.Equal(expected: Cli, actual: console.Program);
        // The ID as it names the session's folder, and nothing of yours.
        Assert.Equal(expected: ["--resume", Id], actual: console.Arguments);
        Assert.Equal(expected: setup.Work, actual: console.WorkingDirectory);
        Assert.Equal(expected: setup.Folder.Path, actual: Assert.Single(collection: console.Environment, predicate: pair => pair.Key == "COPILOT_HOME").Value);
        Assert.False(condition: console.KeepOpen);
        Assert.Empty(collection: setup.Said);

        // While it starts, before its CLI holds it, another click opens nothing more: a second CLI would fork its history.
        Assert.Null(@object: setup.Session.Open(id: Id));
        Assert.Single(collection: setup.Processes.Consoles);
    }

    /// A session a CLI has open is in that CLI's terminal, which comes up, rather than a second one.
    [Fact]
    public async Task BringsUpTheTerminalThatHasItOpen()
    {
        using var setup = new Setup();
        var opening = setup.Session.Open(id: Id);
        await opening!.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        setup.Holder = 4_120;
        Assert.Null(@object: setup.Session.Open(id: Id));
        Assert.Equal(expected: [4_120], actual: setup.Shown);
        Assert.Single(collection: setup.Processes.Consoles);

        // Once that CLI has quit, the next click opens it in a terminal again.
        setup.Holder = null;
        await setup.Session.Open(id: Id)!.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: 2, actual: setup.Processes.Consoles.Count);
    }

    [Fact]
    public async Task SaysWhenItCantFindTheCli()
    {
        using var setup = new Setup(cliInstalled: false);
        await setup.Session.Open(id: Id)!.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        var (message, information) = Assert.Single(collection: setup.Said);
        Assert.Equal(expected: "BriefBar couldn't find the Copilot CLI", actual: message);
        Assert.Equal(
            expected: "Open the session in a terminal yourself with copilot --resume " + Id + ", with COPILOT_HOME set to " + setup.Folder.Path + ".",
            actual: information);
        Assert.Empty(collection: setup.Processes.Consoles);
        // The next click tries again.
        Assert.NotNull(@object: setup.Session.Open(id: Id));
    }

    [Fact]
    public async Task SaysWhenTheSessionsFolderIsGone()
    {
        using var setup = new Setup();
        Directory.Delete(path: setup.Work);
        await setup.Session.Open(id: Id)!.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: "The session's folder isn't there anymore", actual: Assert.Single(collection: setup.Said).Message);
        Assert.Empty(collection: setup.Processes.Consoles);
    }

    [Fact]
    public async Task SaysWhenTheTerminalDidntOpen()
    {
        using var setup = new Setup();
        setup.Processes.FailToStart(failure: new Win32Exception(error: 2));
        await setup.Session.Open(id: Id)!.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: "The session didn't open in a terminal", actual: Assert.Single(collection: setup.Said).Message);
        Assert.NotNull(@object: setup.Session.Open(id: Id));
    }

    /// A `copilot.cmd` at a path with a percent sign, which `cmd.exe` would read as a variable, can't run: `ProcessRunner`
    /// refuses it. That's said too, and the next click tries again, rather than one that opens nothing and says nothing.
    [Fact]
    public async Task SaysWhenTheTerminalDidntOpenForACliCmdCantRun()
    {
        using var setup = new Setup();
        setup.Processes.FailToStart(failure: Assert.Throws<ArgumentException>(testCode: () => new ProcessRunner().StartInConsole(
            program: @"C:\Made up 100%\copilot.cmd", arguments: ["--resume", Id], workingDirectory: null, environment: new Dictionary<string, string?>(), keepOpen: false)));
        await setup.Session.Open(id: Id)!.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(expected: "The session didn't open in a terminal", actual: Assert.Single(collection: setup.Said).Message);
        Assert.NotNull(@object: setup.Session.Open(id: Id));
    }

    /// Copilot turned off while a session starts: it opens nothing, and says nothing.
    [Fact]
    public async Task OpensNothingOnceStopped()
    {
        using var setup = new Setup();
        using var holding = new ManualResetEventSlim(initialState: false);
        using var asked = new ManualResetEventSlim(initialState: false);
        var calls = 0;
        setup.HolderOf = _ =>
        {
            if (Interlocked.Increment(location: ref calls) == 2)
            {
                asked.Set();
                holding.Wait(timeout: Waiting.Limit);
            }
            return null;
        };
        var opening = setup.Session.Open(id: Id)!;
        Assert.True(condition: asked.Wait(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken));
        setup.Session.Stop();
        holding.Set();
        await opening.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Empty(collection: setup.Processes.Consoles);
        Assert.Empty(collection: setup.Said);
    }

    /// Copilot turned off as a session's terminal starts, after it checked it may: stopping waits for that terminal, so
    /// none starts, and nothing is said, once it has stopped.
    [Fact]
    public async Task StoppingWaitsForATerminalThatsStarting()
    {
        using var setup = new Setup();
        using var starting = new ManualResetEventSlim(initialState: false);
        using var started = new ManualResetEventSlim(initialState: false);
        setup.Processes.Starting = () =>
        {
            starting.Set();
            started.Wait(timeout: Waiting.Limit);
        };
        var opening = setup.Session.Open(id: Id)!;
        Task stopping;
        try
        {
            Assert.True(condition: starting.Wait(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken));
            stopping = Task.Run(action: setup.Session.Stop, cancellationToken: TestContext.Current.CancellationToken);
            await Task.WhenAny(task1: stopping, task2: Task.Delay(delay: TimeSpan.FromMilliseconds(value: 300), cancellationToken: TestContext.Current.CancellationToken));
            Assert.False(condition: stopping.IsCompleted, userMessage: "It stopped while a terminal was still starting.");
            Assert.Empty(collection: setup.Processes.Consoles);
        }
        finally
        {
            started.Set();
        }

        await stopping.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        await opening.WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Single(collection: setup.Processes.Consoles);
        Assert.Empty(collection: setup.Said);
    }

    [Fact]
    public void OpensNothingThatIsntASession()
    {
        using var setup = new Setup();
        Assert.Null(@object: setup.Session.Open(id: "not-a-session"));
        Assert.Null(@object: setup.Session.Open(id: @"..\" + Id));
        Assert.Null(@object: setup.Session.Open(id: Id + " --yolo"));
        Assert.Empty(collection: setup.Processes.Consoles);
        Assert.Empty(collection: setup.Shown);
    }

    [Fact]
    public void SaysHowToOpenItYourself()
    {
        var paths = new CopilotPaths(root: @"C:\Users\robin\.copilot");
        Assert.Equal(expected: "copilot --resume " + Id, actual: CLISession.ManualCommand(id: Id, paths: paths, yourHome: @"C:\Users\robin\.copilot\"));
        Assert.Equal(expected: "copilot --resume " + Id, actual: CLISession.ManualCommand(id: Id, paths: paths, yourHome: @"c:\users\ROBIN\.copilot"));
        Assert.Equal(
            expected: "copilot --resume " + Id + @", with COPILOT_HOME set to C:\Users\robin\.copilot",
            actual: CLISession.ManualCommand(id: Id, paths: paths, yourHome: @"D:\Copilot"));
        Assert.Equal(
            expected: "copilot --resume " + Id + @", with COPILOT_HOME set to C:\Users\robin\.copilot",
            actual: CLISession.ManualCommand(id: Id, paths: paths, yourHome: null));
    }

    /// A row of Copilot's panel, on a PC without the app, opens its session in a terminal, as the Mac's does in Terminal.
    [Fact]
    public async Task ARowOpensItsSessionInATerminalWithoutTheApp()
    {
        using var setup = new Setup();
        FakeSessionEngine? made = null;
        using var source = new CopilotSource(
            settings: new CopilotSettings(settings: new MemorySettings(), now: DateTimeOffset.UtcNow),
            makeEngine: onChange => made = new FakeSessionEngine(onChange: onChange),
            app: new CopilotAppAccess(OpenSession: _ => throw new InvalidOperationException(message: "The app isn't installed."), Activate: () => { }, IsInstalled: () => false, IsFrontmost: () => false),
            cliSessions: setup.Session);
        await source.StartAsync(cancellationToken: TestContext.Current.CancellationToken);
        await Waiting.Until(condition: () => made?.Starts == 1);
        made!.Publish(snapshot: new EngineSnapshot { Records = [Ended(id: Id)] });
        var row = Assert.Single(collection: source.Snapshot(section: SectionId.CopilotSessions).Rows);
        Assert.Equal(expected: "Open in a terminal", actual: row.Commands[0].Title);

        source.Perform(request: new CommandRequest(Section: SectionId.CopilotSessions, Command: CopilotCommands.Open, RowId: Id));
        await Waiting.Until(condition: () => setup.Processes.Consoles.Count == 1);
        await source.StopAsync().WaitAsync(timeout: Waiting.Limit, cancellationToken: TestContext.Current.CancellationToken);
    }

    static SessionRecord Ended(string id)
    {
        var at = DateTimeOffset.UtcNow.AddMinutes(minutes: -2);
        var log = new SessionLogState();
        log.Apply(logEvent: new LogEvent(Timestamp: at.AddSeconds(seconds: -30), Kind: LogEventKind.UserMessage));
        log.Apply(logEvent: new LogEvent(Timestamp: at, Kind: LogEventKind.AgentStop(isSubagent: false)));
        return new SessionRecord(Meta: new SessionMeta { Id = id, Name = "Made-up session", WorkspaceId = id }, Log: log);
    }

    /// A Copilot folder of made-up sessions, with one whose `workspace.yaml` says it works in `Work`, a CLI in `C:\Tools`
    /// unless it isn't installed, and what opening it showed and said.
    sealed class Setup : IDisposable
    {
        readonly List<int> shown = [];
        readonly List<(string Message, string Information)> said = [];

        public Setup(bool cliInstalled = true)
        {
            Work = Folder.Combine("work");
            Directory.CreateDirectory(path: Work);
            var paths = new CopilotPaths(root: Folder.Path);
            Directory.CreateDirectory(path: paths.SessionDirectory(id: Id));
            File.WriteAllText(path: Path.Combine(path1: paths.SessionDirectory(id: Id), path2: "workspace.yaml"), contents: "id: " + Id + "\ncwd: " + Work + "\nname: Made-up session\n");
            HolderOf = _ => Holder;
            Session = new CLISession(
                paths: paths,
                locator: new CopilotCLILocator(
                    environment: new Dictionary<string, string?> { ["PATH"] = @"C:\Tools", ["USERPROFILE"] = @"C:\Users\robin" },
                    exists: path => cliInstalled && path == Cli),
                processes: Processes,
                shell: new CLISessionShell(
                    ShowTerminalOf: pid =>
                    {
                        lock (shown)
                        {
                            shown.Add(item: pid);
                        }
                    },
                    Say: (message, information) =>
                    {
                        lock (said)
                        {
                            said.Add(item: (message, information));
                        }
                    }),
                holder: folder => HolderOf(arg: folder));
        }

        public TemporaryFolder Folder { get; } = new();

        public string Work { get; }

        public FakeProcessRunner Processes { get; } = new();

        public CLISession Session { get; }

        /// The process that holds the session, for the default `HolderOf`.
        public int? Holder { get; set; }

        public Func<string, int?> HolderOf { get; set; }

        public IReadOnlyList<int> Shown
        {
            get
            {
                lock (shown)
                {
                    return [.. shown];
                }
            }
        }

        public IReadOnlyList<(string Message, string Information)> Said
        {
            get
            {
                lock (said)
                {
                    return [.. said];
                }
            }
        }

        public void Dispose() => Folder.Dispose();
    }
}
