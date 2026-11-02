namespace BriefBar.Core.AzureDevOps;

/// What `AzureDevOpsSource` asks of Windows, which BriefBar.Core can't do itself: open a page in your browser.
public sealed record AzureDevOpsAccess(Action<Uri> OpenLink);
