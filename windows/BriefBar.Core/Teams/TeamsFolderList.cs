namespace BriefBar.Core.Teams;

/// The Teams site's IndexedDB folders that were found, in order, and how many folders couldn't be listed, which may hold
/// more of them.
public sealed record TeamsFolderList(IReadOnlyList<string> Folders, int Unlistable);
