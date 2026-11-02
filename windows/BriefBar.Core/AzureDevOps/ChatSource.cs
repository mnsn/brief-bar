namespace BriefBar.Core.AzureDevOps;

/// The message that sent you a pull request: the app it came in, and who sent it. The Mac's `ChatSource`, without the
/// link to the message itself, which BriefBar for Windows can't open yet.
public sealed record ChatSource(string App, string AppName, string? Sender);
