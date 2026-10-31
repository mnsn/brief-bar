namespace BriefBar.Core.Tests;

/// Tests that give the log a sink of their own. The log is shared, so they don't run alongside each other.
[CollectionDefinition(name: nameof(SharedLog), DisableParallelization = true)]
public sealed class SharedLog
{
}
