namespace BriefBar.Core.AzureDevOps;

/// A run found after a merge, with its pipeline. The Mac's `PulseEngine.MergeFollow.Found`.
internal sealed record MergeFollowRun(PipelineRef Pipeline, PipelineRun Run);
