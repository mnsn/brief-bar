namespace BriefBar.Core.Tests;

public sealed class ShellCommandTests
{
    [Fact]
    public void FindsTheProgramALinksCommandRuns()
    {
        Assert.Equal(expected: @"C:\Made up\app.exe", actual: ShellCommand.Program(command: "\"C:\\Made up\\app.exe\" \"%1\""));
        Assert.Equal(expected: @"C:\Apps\app.exe", actual: ShellCommand.Program(command: @"C:\Apps\app.exe %1"));
        Assert.Equal(expected: @"C:\Apps\app.exe", actual: ShellCommand.Program(command: @"  C:\Apps\app.exe"));
    }

    [Fact]
    public void FindsNoneInACommandWithoutOne()
    {
        Assert.Null(@object: ShellCommand.Program(command: null));
        Assert.Null(@object: ShellCommand.Program(command: "   "));
        Assert.Null(@object: ShellCommand.Program(command: "\"\" \"%1\""));
        Assert.Null(@object: ShellCommand.Program(command: "\"C:\\Never closed"));
    }
}
