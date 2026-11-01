using System.ComponentModel;
using BriefBar.Core.Logging;

namespace BriefBar.Core.Copilot;

/// Opening a session on a PC without the GitHub Copilot app, as with only the Copilot CLI, where nothing opens the app's
/// `ghapp:` links. A session a CLI still has open (`SessionLock`) is in the terminal that CLI runs in, which comes to the
/// front: going on with it in a second one would fork its history. Any other goes on in a new terminal window with
/// `copilot --resume`, in the folder it works in, and with the Copilot folder BriefBar found it in. While it starts there,
/// before its CLI holds it, another click opens nothing more (`StartingSessions`). The Mac's `CLISession`, which opens
/// Terminal.
public sealed class CLISession
{
    /// What the CLI is run with, besides the session: nothing of yours, so a batch file can take it too.
    const string ResumeOption = "--resume";

    readonly CopilotPaths paths;
    readonly CopilotCLILocator locator;
    readonly IProcessRunner processes;
    readonly CLISessionShell shell;
    readonly Func<string, int?> holder;
    readonly TimeProvider time;
    readonly StartingSessions starting = new();

    /// - `paths`: where BriefBar found the sessions.
    /// - `locator`: finds `copilot`, and the Copilot folder it uses by itself.
    /// - `processes`: starts it in a terminal.
    /// - `shell`: brings up a terminal, and tells you what went wrong.
    /// - `holder`: the process that holds a session, by its folder: `SessionLock.Holder`, unless a test says otherwise.
    public CLISession(
        CopilotPaths paths, CopilotCLILocator locator, IProcessRunner processes, CLISessionShell shell, Func<string, int?>? holder = null, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(argument: paths);
        ArgumentNullException.ThrowIfNull(argument: locator);
        ArgumentNullException.ThrowIfNull(argument: processes);
        ArgumentNullException.ThrowIfNull(argument: shell);
        this.paths = paths;
        this.locator = locator;
        this.processes = processes;
        this.shell = shell;
        this.holder = holder ?? SessionLock.Holder;
        this.time = time ?? TimeProvider.System;
    }

    /// Opens session `id`: brings up the terminal that has it, or starts it in a new one, on the thread pool, which the
    /// task returned does. An ID that isn't a session's, or one already starting, opens nothing.
    public Task? Open(string id)
    {
        // A session's ID is a UUID, which names its folder in lowercase: nothing else reaches the CLI's command line.
        if (!Guid.TryParseExact(input: id, format: "D", result: out var uuid))
        {
            return null;
        }
        var session = uuid.ToString(format: "D");
        if (holder(arg: paths.SessionDirectory(id: session)) is { } pid)
        {
            starting.End(id: session);
            shell.ShowTerminalOf(obj: pid);
            return null;
        }
        // Its CLI may not hold it yet: a second one would fork its history.
        if (!starting.Begin(id: session, now: time.GetUtcNow()))
        {
            return null;
        }
        var round = starting.Round;
        return Task.Run(action: () => Resume(id: session, round: round));
    }

    /// Stops opening sessions in a terminal, as Copilot is turned off or BriefBar quits: one that's still starting opens
    /// nothing.
    public void Stop() => starting.StopAll();

    /// How to open session `id` yourself: `copilot --resume <id>`, with `COPILOT_HOME` set to `paths`' folder when the CLI
    /// wouldn't use that by itself (`yourHome`), as when `BRIEFBAR_COPILOT_DIR` names another.
    public static string ManualCommand(string id, CopilotPaths paths, string? yourHome)
    {
        ArgumentNullException.ThrowIfNull(argument: paths);
        var command = "copilot " + ResumeOption + " " + id;
        return yourHome is not null && SameFolder(first: yourHome, second: paths.Root)
            ? command
            : command + ", with COPILOT_HOME set to " + paths.Root;
    }

    static bool SameFolder(string first, string second) => string.Equals(
        a: Path.TrimEndingDirectorySeparator(path: Path.GetFullPath(path: first)),
        b: Path.TrimEndingDirectorySeparator(path: Path.GetFullPath(path: second)),
        comparisonType: StringComparison.OrdinalIgnoreCase);

    /// Goes on with it in a new terminal window: the CLI, wherever BriefBar finds it, resumes it in its folder, from the
    /// Copilot folder BriefBar found it in. Only while opening hasn't stopped since `round` (`Stop`): turned off meanwhile,
    /// Copilot opens nothing, and says nothing.
    void Resume(string id, int round)
    {
        // A CLI may have opened it meanwhile.
        var pid = holder(arg: paths.SessionDirectory(id: id));
        var copilot = pid is null ? locator.Locate() : null;
        var folder = copilot is null ? null : SessionStateScanner.WorkingFolder(directory: paths.SessionDirectory(id: id));
        if (starting.Round != round)
        {
            return;
        }
        if (pid is { } holderId)
        {
            starting.End(id: id);
            shell.ShowTerminalOf(obj: holderId);
            return;
        }
        var command = ManualCommand(id: id, paths: paths, yourHome: locator.Home);
        if (copilot is null)
        {
            Fail(id: id, message: "BriefBar couldn't find the Copilot CLI", information: "Open the session in a terminal yourself with " + command + ".");
            return;
        }
        if (folder is null)
        {
            Fail(
                id: id,
                message: "The session's folder isn't there anymore",
                information: "Copilot worked on it in a folder that's gone, such as a worktree that was removed. To go on with it anyway, run " + command + " in a terminal.");
            return;
        }
        try
        {
            processes.StartInConsole(
                program: copilot,
                arguments: [ResumeOption, id],
                workingDirectory: folder,
                environment: new Dictionary<string, string?>(comparer: StringComparer.Ordinal) { ["COPILOT_HOME"] = paths.Root },
                keepOpen: false);
            Log.Write(line: $"copilot: opening a session in a terminal");
            // It stays starting until its CLI holds it, or for a while.
            return;
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or IOException)
        {
            Log.Write(error: error, context: $"copilot: couldn't open a session in a terminal");
        }
        Fail(id: id, message: "The session didn't open in a terminal", information: "Open it in a terminal yourself with " + command + ".");
    }

    /// It couldn't be opened, for what `message` and `information` say: the next click tries again.
    void Fail(string id, string message, string information)
    {
        starting.End(id: id);
        shell.Say(arg1: message, arg2: information);
    }
}
