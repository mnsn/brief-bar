import BriefBarCore
import Foundation

/// Whether a program has a session open. The Copilot app's runtime keeps `inuse.<pid>.lock` in a session's folder while
/// it has the session loaded, with its history in memory: a turn that another program, such as the Copilot CLI, runs in
/// the session meanwhile is one the app never sees, and the session's history forks. The CLI doesn't check for it.
public enum SessionLock {
    /// Whether a program that's still running holds the session in `folder`. A lock left by one that's gone, as after the
    /// app quits, doesn't count; nor does one whose process ID a program that started after it was written has now, since
    /// macOS reuses them.
    public static func isHeld(
        sessionFolder folder: URL, isRunning: (pid_t) -> Bool = SessionLock.isRunning,
        startTime: (pid_t) -> Date? = DetachedProgram.startTime(of:)
    ) -> Bool {
        holders(in: folder).contains { lock in
            guard isRunning(lock.pid) else { return false }
            guard let written = lock.written, let started = startTime(lock.pid) else { return true }
            // Start times and modification dates are both precise to well under a second.
            return started <= written.addingTimeInterval(1)
        }
    }

    /// The programs that left a lock in the folder, by their process IDs, with when each lock was written.
    static func holders(in folder: URL) -> [(pid: pid_t, written: Date?)] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name in
            guard let pid = pid(inLockNamed: name) else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            return (pid, attributes?[.modificationDate] as? Date)
        }
    }

    /// 123, from `inuse.123.lock`; nil for any other name.
    static func pid(inLockNamed name: String) -> pid_t? {
        guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else { return nil }
        let digits = name.dropFirst("inuse.".count).dropLast(".lock".count)
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let pid = pid_t(digits), pid > 0
        else { return nil }
        return pid
    }

    /// Whether a process with this ID is running, rather than gone or a zombie.
    public static func isRunning(_ pid: pid_t) -> Bool {
        DetachedProgram.isRunning(DetachedProgram.Handle(pid: pid, startedAt: nil))
    }
}
