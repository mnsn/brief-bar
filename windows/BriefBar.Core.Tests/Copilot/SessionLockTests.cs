using BriefBar.Core.Copilot;

namespace BriefBar.Core.Tests.Copilot;

/// Whether a program has a session open, by the `inuse.<pid>.lock` files the Copilot app's runtime and the Copilot CLI
/// keep in its folder, as the Mac's `SessionLockTests` do.
public sealed class SessionLockTests
{
    static readonly DateTimeOffset written = TestTimes.T(seconds: 0);

    [Fact]
    public void ReadsAProcessIdFromALocksName()
    {
        Assert.Equal(expected: 123, actual: SessionLock.PidInLockNamed(name: "inuse.123.lock"));
        Assert.Null(@object: SessionLock.PidInLockNamed(name: "inuse..lock"));
        Assert.Null(@object: SessionLock.PidInLockNamed(name: "inuse.0.lock"));
        Assert.Null(@object: SessionLock.PidInLockNamed(name: "inuse.-4.lock"));
        Assert.Null(@object: SessionLock.PidInLockNamed(name: "inuse.12a.lock"));
        Assert.Null(@object: SessionLock.PidInLockNamed(name: "inuse.12345678901.lock"));
        Assert.Null(@object: SessionLock.PidInLockNamed(name: "inuse.99999999999.lock"));
        Assert.Null(@object: SessionLock.PidInLockNamed(name: "inuse.123.lock.tmp"));
        Assert.Null(@object: SessionLock.PidInLockNamed(name: "events.jsonl"));
        // Digits other than ASCII's aren't a process ID.
        Assert.Null(@object: SessionLock.PidInLockNamed(name: "inuse.١٢٣.lock"));
    }

    /// The program that wrote the lock and still runs holds the session.
    [Fact]
    public void FindsTheProgramThatHoldsTheSession()
    {
        using var folder = new TemporaryFolder();
        Lock(folder: folder, pid: 4_120);
        Assert.Equal(expected: 4_120, actual: SessionLock.Holder(folder: folder.Path, isRunning: _ => true, startTime: _ => written.AddMinutes(minutes: -5)));
        // One whose start time Windows won't tell still counts.
        Assert.Equal(expected: 4_120, actual: SessionLock.Holder(folder: folder.Path, isRunning: _ => true, startTime: _ => null));
    }

    /// A lock left by a program that's gone, as after the CLI quits, or whose process ID a program that started later has
    /// now, doesn't count.
    [Fact]
    public void PassesOverLocksOfProgramsThatAreGone()
    {
        using var folder = new TemporaryFolder();
        Lock(folder: folder, pid: 4_120);
        Lock(folder: folder, pid: 4_124);
        Assert.Null(@object: SessionLock.Holder(folder: folder.Path, isRunning: _ => false, startTime: _ => written));
        Assert.Null(@object: SessionLock.Holder(folder: folder.Path, isRunning: _ => true, startTime: _ => written.AddMinutes(minutes: 1)));
        // Within a second of the lock, it's the program that wrote it.
        Assert.Equal(
            expected: 4_124,
            actual: SessionLock.Holder(folder: folder.Path, isRunning: pid => pid == 4_124, startTime: _ => written.AddMilliseconds(milliseconds: 900)));
    }

    [Fact]
    public void NoFolderHoldsNothing()
    {
        using var folder = new TemporaryFolder();
        Assert.Null(@object: SessionLock.Holder(folder: folder.Combine("not-there"), isRunning: _ => true, startTime: _ => null));
        Assert.Null(@object: SessionLock.Holder(folder: folder.Path, isRunning: _ => true, startTime: _ => null));
    }

    /// Windows says what runs: BriefBar's own tests do, and started before now.
    [Fact]
    public void AsksWindowsWhatRuns()
    {
        Assert.True(condition: ProcessRunner.IsRunning(pid: Environment.ProcessId));
        Assert.True(condition: ProcessRunner.StartTime(pid: Environment.ProcessId) <= DateTimeOffset.Now);
        Assert.False(condition: ProcessRunner.IsRunning(pid: -1));
        Assert.Null(@object: ProcessRunner.StartTime(pid: -1));
    }

    static void Lock(TemporaryFolder folder, int pid)
    {
        var path = folder.Combine("inuse." + pid.ToString(provider: System.Globalization.CultureInfo.InvariantCulture) + ".lock");
        File.WriteAllText(path: path, contents: string.Empty);
        File.SetLastWriteTimeUtc(path: path, lastWriteTimeUtc: written.UtcDateTime);
    }
}
