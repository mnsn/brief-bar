namespace BriefBar.Core.AzureDevOps;

/// A pipeline: its organization, project, ID, name and folder. The Mac's `PipelineRef`, which the Pipelines section
/// also pins.
public sealed record PipelineRef(string Organization, string ProjectId, string ProjectName, int DefinitionId, string Name, string Folder = "")
{
    public string Id => Organization + "/" + ProjectId + "/" + DefinitionId.ToString(provider: System.Globalization.CultureInfo.InvariantCulture);

    /// The folder it's in, without its leading backslash, such as `Storefront\CI`; empty at the top.
    public static string FolderOf(string? path) => (path ?? string.Empty).Trim(trimChar: '\\');
}
