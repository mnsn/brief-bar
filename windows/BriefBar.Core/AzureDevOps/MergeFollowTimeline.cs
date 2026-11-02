namespace BriefBar.Core.AzureDevOps;

/// What a run's timeline said: its stages, where it failed, and the run's status when it was read, since a finished run's
/// is read once more. The Mac's `PulseEngine.MergeFollow.Timeline`.
internal sealed record MergeFollowTimeline(ValueList<PipelineStage> Stages, PipelineFailure? Failure, PipelineRunStatus ReadFor, DateTimeOffset ReadAt);
