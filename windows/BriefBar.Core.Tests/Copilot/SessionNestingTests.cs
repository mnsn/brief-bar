using BriefBar.Core.Copilot;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class SessionNestingTests
{
    /// The most recent first, in Running; a family goes where its most recent member would.
    [Fact]
    public void NestsSessionsUnderTheirParentsInTheSameGroup()
    {
        SessionSnapshot[] snapshots =
        [
            Snapshot(id: "lead", phase: DisplayPhase.Running, since: 0), Snapshot(id: "other", phase: DisplayPhase.Running, since: 10),
            Snapshot(id: "child", phase: DisplayPhase.Running, since: 20), Snapshot(id: "grandchild", phase: DisplayPhase.Running, since: 5),
        ];
        Assert.Equal(expected: ["child", "other", "grandchild", "lead"], actual: Outline(snapshots: SessionOrdering.Sorted(snapshots: snapshots)));

        var sessions = Nested(snapshots: snapshots, parents: new() { ["child"] = "lead", ["grandchild"] = "child" });
        Assert.Equal(expected: ["lead", "  child", "    grandchild", "other"], actual: Outline(snapshots: sessions));
        Assert.Equal(
            expected: [null, new RelatedSession(Id: "lead", Name: "Lead"), new RelatedSession(Id: "child", Name: "Child"), null],
            actual: sessions.Select(selector: session => session.Parent));
        Assert.Equal(expected: new PhaseCounts(snapshots: snapshots), actual: new PhaseCounts(snapshots: sessions));
    }

    /// The longest wait first, in Needs you: a parent comes first, then its children, the longest-waiting first.
    [Fact]
    public void AFamilyTakesThePlaceOfItsFirstMember()
    {
        SessionSnapshot[] snapshots =
        [
            Snapshot(id: "other", phase: DisplayPhase.NeedsYou, since: 10), Snapshot(id: "lead", phase: DisplayPhase.NeedsYou, since: 30),
            Snapshot(id: "first", phase: DisplayPhase.NeedsYou, since: 0), Snapshot(id: "second", phase: DisplayPhase.NeedsYou, since: 20),
        ];
        Assert.Equal(expected: ["first", "other", "second", "lead"], actual: Outline(snapshots: SessionOrdering.Sorted(snapshots: snapshots)));
        Assert.Equal(
            expected: ["lead", "  first", "  second", "other"],
            actual: Outline(snapshots: Nested(snapshots: snapshots, parents: new() { ["first"] = "lead", ["second"] = "lead" })));
    }

    /// A session whose parent is in another group stays in its place, and knows its parent, for its tag.
    [Fact]
    public void ASessionWhoseParentIsInAnotherGroupStaysInItsPlace()
    {
        SessionSnapshot[] snapshots =
        [
            Snapshot(id: "child", phase: DisplayPhase.NeedsYou, since: 0), Snapshot(id: "other", phase: DisplayPhase.NeedsYou, since: 10),
            Snapshot(id: "busy", phase: DisplayPhase.Running, since: 30), Snapshot(id: "lead", phase: DisplayPhase.Running, since: 5),
        ];
        var sessions = Nested(snapshots: snapshots, parents: new() { ["child"] = "lead" });
        Assert.Equal(expected: ["child", "other", "busy", "lead"], actual: Outline(snapshots: sessions));
        Assert.Equal(expected: new RelatedSession(Id: "lead", Name: "Lead"), actual: sessions[0].Parent);
        Assert.All(collection: sessions.Skip(count: 1), action: session => Assert.Null(@object: session.Parent));
    }

    /// One whose parent isn't listed, such as one archived, isn't nested or tagged.
    [Fact]
    public void AParentThatIsntListedChangesNothing()
    {
        SessionSnapshot[] snapshots = [Snapshot(id: "child", phase: DisplayPhase.Running, since: 10), Snapshot(id: "other", phase: DisplayPhase.Running, since: 0)];
        var sorted = SessionOrdering.Sorted(snapshots: snapshots);
        Assert.Equal(expected: sorted, actual: Nested(snapshots: snapshots, parents: new() { ["child"] = "archived" }));
        Assert.Equal(expected: sorted, actual: Nested(snapshots: snapshots, parents: new() { ["child"] = "child" }));
        Assert.Equal(expected: sorted, actual: Nested(snapshots: snapshots, parents: []));
    }

    /// Sessions recorded as each other's parents are all still listed: the one that sorts first heads them.
    [Fact]
    public void KeepsSessionsRecordedAsEachOthersParents()
    {
        SessionSnapshot[] snapshots =
        [
            Snapshot(id: "a", phase: DisplayPhase.Running, since: 10), Snapshot(id: "b", phase: DisplayPhase.Running, since: 5),
            Snapshot(id: "c", phase: DisplayPhase.Running, since: 20),
        ];
        var sessions = Nested(snapshots: snapshots, parents: new() { ["a"] = "b", ["b"] = "c", ["c"] = "a" });
        Assert.Equal(expected: ["c", "  b", "    a"], actual: Outline(snapshots: sessions));
        Assert.All(collection: sessions, action: session => Assert.NotNull(@object: session.Parent));
    }

    /// Two snapshots with one ID, which a list never has, can't be told apart: nothing is nested.
    [Fact]
    public void LeavesAListWithRepeatedIdsAsItIs()
    {
        SessionSnapshot[] snapshots =
        [
            Snapshot(id: "lead", phase: DisplayPhase.Running, since: 0), Snapshot(id: "child", phase: DisplayPhase.Running, since: 10),
            Snapshot(id: "child", phase: DisplayPhase.Idle, since: 5),
        ];
        SessionRecord[] records = [new(Meta: new SessionMeta { Id = "child", Name = "Child", ParentSessionId = "lead" }, Log: null)];
        Assert.Equal(expected: snapshots, actual: SessionNesting.Nest(snapshots: snapshots, records: records));
    }

    static SessionSnapshot Snapshot(string id, DisplayPhase phase, double since)
    {
        var reason = phase == DisplayPhase.NeedsYou ? StatusReason.Question : StatusReason.Working;
        return new SessionSnapshot
        {
            Id = id,
            Name = char.ToUpperInvariant(c: id[0]) + id[1..],
            Phase = phase,
            Reason = reason,
            Headline = reason.Headline(),
            Since = T(seconds: since),
        };
    }

    /// The snapshots as the list sorts them, then nested by the parents the app records.
    static List<SessionSnapshot> Nested(SessionSnapshot[] snapshots, Dictionary<string, string> parents)
    {
        var records = snapshots.Select(selector: snapshot => new SessionRecord(
            Meta: new SessionMeta { Id = snapshot.Id, Name = snapshot.Name, ParentSessionId = parents.GetValueOrDefault(key: snapshot.Id) },
            Log: null)).ToList();
        return SessionNesting.Nest(snapshots: SessionOrdering.Sorted(snapshots: snapshots), records: records);
    }

    /// Each session's ID, indented as deep as it's nested.
    static List<string> Outline(IEnumerable<SessionSnapshot> snapshots) =>
        snapshots.Select(selector: snapshot => new string(c: ' ', count: snapshot.Depth * 2) + snapshot.Id).ToList();
}
