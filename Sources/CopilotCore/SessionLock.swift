import BriefBarCore
import Foundation

/// Whether a program has a session open. The Copilot app's runtime keeps `inuse.<pid>.lock` in a session's folder while
/// it has the session loaded, with its history in memory: a turn that another program, such as the Copilot CLI, runs in
/// the session meanwhile is one the app never sees, and the session's history forks. The CLI doesn't check for it.
public enum SessionLock {
    /// Whether a program that's still running holds the session in `folder`. A lock left by one that's gone, as after the
    /// app quits, doesn't count.
    public static func isHeld(sessionFolder folder: URL, isRunning: (pid_t) -> Bool = SessionLock.isRunning) -> Bool {
        holders(in: folder).contains(where: isRunning)
    }

    /// The programs that left a lock in the folder, by their process IDs.
    static func holders(in folder: URL) -> [pid_t] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap(pid(inLockNamed:))
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
