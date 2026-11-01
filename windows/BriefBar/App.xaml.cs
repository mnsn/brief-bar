using BriefBar.Core;
using BriefBar.Core.Demo;
using BriefBar.Core.Logging;
using BriefBar.Services;
using BriefBar.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace BriefBar;

/// BriefBar for Windows: a bar on every display, and a panel under each of its items. It quits only when you ask, from
/// a menu or windows/scripts/quit.ps1, and gives the bars' space back on every way out.
public sealed partial class App : Application
{
    readonly LaunchOptions options;
    readonly SingleInstance instance;
    /// Gives every bar's space back, should BriefBar end unexpectedly. The shell disposes itself as it quits.
    Action? giveSpaceBack;

    internal App(LaunchOptions options, SingleInstance instance)
    {
        this.options = options;
        this.instance = instance;
        InitializeComponent();
        // Bars come and go with displays, and the panel hides rather than closes: BriefBar quits only when asked.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += OnUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        UseLogFile();
        Log.Write(line: $"started: demo {options.IsDemo}, process {Environment.ProcessId}");
        var queue = DispatcherQueue.GetForCurrentThread();
        IReadOnlyList<ISectionSource> sources = options.IsDemo ? DemoSource.All(madeAt: DateTimeOffset.Now) : [];
        var shell = new AppShell(queue: queue, sources: sources, isDemo: options.IsDemo, exit: Exit);
        giveSpaceBack = shell.GiveSpaceBack;
        instance.Listen(queue: queue, quit: shell.Quit, show: shell.ShowOverview);
        shell.Start();
    }

    /// Logs to `%LOCALAPPDATA%\BriefBar\Logs`, or nowhere when that folder can't be made: BriefBar runs either way.
    static void UseLogFile()
    {
        try
        {
            Log.UseSink(newSink: FileLogSink.Open());
        }
        catch (IOException)
        {
            Log.UseSink(newSink: null);
        }
        catch (UnauthorizedAccessException)
        {
            Log.UseSink(newSink: null);
        }
    }

    void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
    {
        Log.Write(error: e.Exception, context: $"unhandled on the UI thread; quitting");
        // BriefBar can't know what state that left it in: every bar gives its space back at once, and it ends, rather
        // than run on without its windows.
        giveSpaceBack?.Invoke();
        Environment.Exit(exitCode: 1);
    }

    static void OnDomainUnhandledException(object sender, System.UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception error)
        {
            Log.Write(error: error, context: $"unhandled; quitting");
        }
    }

    static void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e) =>
        Log.Write(error: e.Exception, context: $"a task failed and nothing waited for it");
}
