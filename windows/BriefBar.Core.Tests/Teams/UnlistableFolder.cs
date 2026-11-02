using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace BriefBar.Core.Tests.Teams;

/// A folder you can't list until it's disposed of, as Windows' access control can deny a program a folder: it's there, but
/// what it holds can't be found.
[SupportedOSPlatform(platformName: "windows")]
internal sealed class UnlistableFolder : IDisposable
{
    readonly DirectoryInfo directory;
    readonly FileSystemAccessRule denial;

    public UnlistableFolder(string path)
    {
        directory = Directory.CreateDirectory(path: path);
        using var identity = WindowsIdentity.GetCurrent();
        denial = new FileSystemAccessRule(identity: identity.User!, fileSystemRights: FileSystemRights.ListDirectory, type: AccessControlType.Deny);
        var security = directory.GetAccessControl();
        security.AddAccessRule(rule: denial);
        directory.SetAccessControl(directorySecurity: security);
    }

    public void Dispose()
    {
        var security = directory.GetAccessControl();
        security.RemoveAccessRule(rule: denial);
        directory.SetAccessControl(directorySecurity: security);
    }
}
