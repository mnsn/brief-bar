using System.Runtime.CompilerServices;
using System.Text;

namespace BriefBar.Core.Tests;

/// The tests' own program, as one that only prints the arguments it got when it starts with `Variable` set to 1: each in
/// brackets, on a line of its own, in UTF-8. `ProcessRunnerTests` runs it as a program that isn't a batch file and that
/// starts at once.
internal static class ArgumentsEcho
{
    public const string Variable = "BRIEFBAR_TESTS_PRINT_ARGUMENTS";

    /// The tests' program, as Windows starts it.
    public static string Program { get; } = Path.Combine(path1: AppContext.BaseDirectory, path2: "BriefBar.Core.Tests.exe");

    /// What it prints for `arguments`.
    public static string Printed(IEnumerable<string> arguments) => string.Concat(values: arguments.Select(selector: argument => "[" + argument + "]\r\n"));

    /// Runs as the program starts, before its `Main`, so that no tests run then.
    [ModuleInitializer]
    internal static void PrintArgumentsIfAsked()
    {
        if (Environment.GetEnvironmentVariable(variable: Variable) != "1")
        {
            return;
        }
        using (var output = Console.OpenStandardOutput())
        {
            output.Write(buffer: Encoding.UTF8.GetBytes(s: Printed(arguments: Environment.GetCommandLineArgs().Skip(count: 1))));
        }
        Environment.Exit(exitCode: 0);
    }
}
