using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace BriefBar.Core.Tests.Teams;

/// A folder Windows' access control denies you some of, until it's disposed of, as it can deny a program a folder: listing
/// it, unless `rights` says otherwise.
[SupportedOSPlatform(platformName: "windows")]
internal sealed class DeniedFolder : IDisposable
{
    readonly DirectoryInfo directory;
    readonly FileSystemAccessRule denial;

    public DeniedFolder(string path, FileSystemRights rights = FileSystemRights.ListDirectory)
    {
        directory = Directory.CreateDirectory(path: path);
        using var identity = WindowsIdentity.GetCurrent();
        denial = new FileSystemAccessRule(identity: identity.User!, fileSystemRights: rights, type: AccessControlType.Deny);
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
