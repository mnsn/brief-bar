namespace BriefBar.Core.Copilot;

/// How many sessions are in each group. The Mac's `PhaseCounts`.
public record struct PhaseCounts
{
    public PhaseCounts(IEnumerable<SessionSnapshot> snapshots)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        foreach (var snapshot in snapshots)
        {
            this[snapshot.Phase] += 1;
        }
    }

    public int NeedsYou { get; set; }

    public int Running { get; set; }

    public int Done { get; set; }

    public int Stopped { get; set; }

    public int Idle { get; set; }

    /// Sessions worth showing: everything but idle.
    public readonly int Active => NeedsYou + Running + Done + Stopped;

    /// The sessions the bar counts, by state, for an item that adds them up across sources.
    public readonly StateCounts States
    {
        get
        {
            var counts = this;
            return StateCounts.FromGroups(groups: DisplayPhases.All, count: phase => counts[phase], state: phase => phase.State());
        }
    }

    public int this[DisplayPhase phase]
    {
        readonly get => phase switch
        {
            DisplayPhase.NeedsYou => NeedsYou,
            DisplayPhase.Running => Running,
            DisplayPhase.Done => Done,
            DisplayPhase.Stopped => Stopped,
            DisplayPhase.Idle => Idle,
            _ => throw new ArgumentOutOfRangeException(paramName: nameof(phase), actualValue: phase, message: "Not a phase."),
        };
        set
        {
            switch (phase)
            {
                case DisplayPhase.NeedsYou:
                    NeedsYou = value;
                    break;
                case DisplayPhase.Running:
                    Running = value;
                    break;
                case DisplayPhase.Done:
                    Done = value;
                    break;
                case DisplayPhase.Stopped:
                    Stopped = value;
                    break;
                case DisplayPhase.Idle:
                    Idle = value;
                    break;
                default:
                    throw new ArgumentOutOfRangeException(paramName: nameof(phase), actualValue: phase, message: "Not a phase.");
            }
        }
    }
}
