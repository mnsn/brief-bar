namespace BriefBar.Core.AzureDevOps;

/// Whether BriefBar is finding your organizations, the first time.
public enum PRDiscovery
{
    Idle,
    Running,
    Failed,
}
