import Foundation
@testable import CopilotTasks

/// A stand-in for the Copilot CLI, as the real one behaves for forks and side questions. As `copilot --headless --stdio`,
/// it answers BriefBar's JSON-RPC requests, each after a `Content-Length` header, as the CLI's server does: connect,
/// sessions.fork, session.resume, session.ui.ephemeralQuery and session.delete, and nothing else; while it answers a
/// question, it says something unasked and asks something of its own, as the server does. Each message it gets goes to
/// `$FAKE_SERVER_LOG`, one a line. A fork's folder is made in `$COPILOT_HOME/session-state`, with a copy of the session's
/// log, as the CLI copies it, and a deleted session's removed, unless the file `$FAKE_DELETE_FAILS` names is there. What it
/// answers follows `FAKE_VERSION`, `FAKE_FORK` (`unsupported`, `fails`, `hang`, `late`, a second late, `gated`, once the
/// file `$FAKE_FORK_GATE` names is there, or `garbled`, with what isn't a header right after its answer), `FAKE_FORK_ID`
/// and `FAKE_ANSWER` (`hang`, `exit`, `signed-out`, or the answer). As `copilot -p`, it writes its arguments to `$FAKE_COPILOT_ARGUMENTS` and a session log ending with the task
/// done, as `CopilotLauncherTests`' does; or, with `FAKE_RUN=fails`, refuses its options, as the CLI does, before it
/// writes anything to the log.
enum FakeCopilot {
    static let script = #"""
        #!/bin/sh
        if [ "$1" != "--headless" ]; then
          printf '%s\n' "$@" > "$FAKE_COPILOT_ARGUMENTS"
          if [ "$FAKE_RUN" = fails ]; then
            echo "error: unknown option '--autopilot'" >&2
            exit 1
          fi
          while [ $# -gt 0 ]; do
            case "$1" in
              --session-id) id="$2"; shift 2 ;;
              *) shift ;;
            esac
          done
          log="$COPILOT_HOME/session-state/$id/events.jsonl"
          mkdir -p "$(dirname "$log")"
          printf '%s\n' '{"type":"session.task_complete","data":{"summary":"Done.","success":true},"id":"e1","timestamp":"2026-11-02T10:00:00.000Z","parentId":null}' >> "$log"
          exit 0
        fi
        send() {
          printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1"
        }
        answer() {
          send "{\"jsonrpc\":\"2.0\",\"id\":$1,\"result\":$2}"
        }
        refuse() {
          send "{\"jsonrpc\":\"2.0\",\"id\":$1,\"error\":{\"code\":$2,\"message\":\"$3\"}}"
        }
        makefork() {
          from=$(printf '%s' "$1" | sed -n 's/.*"sessionId":"\([0-9a-f-]\{36\}\)".*/\1/p')
          mkdir -p "$COPILOT_HOME/session-state/$FAKE_FORK_ID"
          if [ -n "$from" ] && [ -f "$COPILOT_HOME/session-state/$from/events.jsonl" ]; then
            cp "$COPILOT_HOME/session-state/$from/events.jsonl" "$COPILOT_HOME/session-state/$FAKE_FORK_ID/events.jsonl"
          fi
        }
        while :; do
          length=
          while IFS= read -r line; do
            line=$(printf '%s' "$line" | tr -d '\r')
            [ -z "$line" ] && break
            case "$line" in
              Content-Length:*) length=$(printf '%s' "${line#Content-Length:}" | tr -d ' ') ;;
            esac
          done
          [ -n "$length" ] || exit 0
          body=$(dd bs=1 count="$length" 2>/dev/null)
          printf '%s\n' "$body" >> "$FAKE_SERVER_LOG"
          id=$(printf '%s' "$body" | sed -n 's/^{"id":\([0-9][0-9]*\),.*/\1/p')
          method=$(printf '%s' "$body" | sed -n 's/^{"id":[0-9][0-9]*,"jsonrpc":"2.0","method":"\([^"]*\)".*/\1/p')
          [ -n "$method" ] || continue
          case "$method" in
            connect) answer "$id" "{\"ok\":true,\"protocolVersion\":3,\"version\":\"${FAKE_VERSION:-1.0.105}\"}" ;;
            sessions.fork)
              case "$FAKE_FORK" in
                unsupported) refuse "$id" -32601 "Unhandled method sessions.fork" ;;
                fails) refuse "$id" -32603 "Request sessions.fork failed with message: Cannot fork session: no persisted or in-memory events found" ;;
                hang) ;;
                late) sleep 1; makefork "$body"; answer "$id" "{\"sessionId\":\"$FAKE_FORK_ID\",\"name\":\"fork\"}" ;;
                gated)
                  while [ ! -e "$FAKE_FORK_GATE" ]; do sleep 0.05; done
                  makefork "$body"; answer "$id" "{\"sessionId\":\"$FAKE_FORK_ID\",\"name\":\"fork\"}" ;;
                garbled)
                  makefork "$body"
                  reply="{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"$FAKE_FORK_ID\",\"name\":\"fork\"}}"
                  printf 'Content-Length: %d\r\n\r\n%sNot a header\r\n\r\n' "${#reply}" "$reply" ;;
                *) makefork "$body"; answer "$id" "{\"sessionId\":\"$FAKE_FORK_ID\",\"name\":\"fork\"}" ;;
              esac ;;
            session.resume) answer "$id" "{\"sessionId\":\"$FAKE_FORK_ID\",\"isRemote\":false}" ;;
            session.ui.ephemeralQuery)
              send '{"jsonrpc":"2.0","method":"session.event","params":{"event":{"type":"ui.ephemeral_query","data":{"phase":"started"}}}}'
              send '{"jsonrpc":"2.0","id":"server-1","method":"permission.request","params":{}}'
              case "$FAKE_ANSWER" in
                hang) ;;
                exit) exit 3 ;;
                signed-out) refuse "$id" -32603 "Request session.ui.ephemeralQuery failed with message: Error: No authentication information found." ;;
                *) answer "$id" "{\"answer\":\"${FAKE_ANSWER:-Sam wants the retries capped.}\"}" ;;
              esac ;;
            session.delete)
              session=$(printf '%s' "$body" | sed -n 's/.*"sessionId":"\([0-9a-f-]\{36\}\)".*/\1/p')
              if [ -n "$FAKE_DELETE_FAILS" ] && [ -e "$FAKE_DELETE_FAILS" ]; then
                answer "$id" '{"success":false,"error":"The session is busy."}'
              elif [ -n "$session" ]; then
                rm -rf "$COPILOT_HOME/session-state/$session"
                answer "$id" '{"success":true}'
              else
                answer "$id" '{"success":false,"error":"Session file not found."}'
              fi ;;
            *) refuse "$id" -32601 "Unhandled method $method" ;;
          esac
        done
        """#

    /// The session forked, and its fork, as the stand-in names it.
    static let session = "0b5b1c55-1111-4222-8333-944455556666"
    static let fork = "2f7c4e1a-5b3d-4c8e-9a6f-1d2e3f4a5b6c"

    /// The stand-in, in a temporary folder of its own, with a Copilot folder that has `session`'s log.
    struct Fixture {
        let folder: URL
        let copilot: URL
        let home: URL
        let log: URL
        let arguments: URL
        var environment: [String: String]

        /// - Parameter settings: what it answers (`FAKE_VERSION`, `FAKE_FORK`, `FAKE_ANSWER`).
        init(in folder: URL? = nil, base: [String: String] = [:], _ settings: [String: String] = [:]) throws {
            self.folder = try folder ?? makeTemporaryDirectory()
            copilot = self.folder.appendingPathComponent("bin/copilot")
            home = self.folder.appendingPathComponent("copilot-home")
            log = self.folder.appendingPathComponent("server.log")
            arguments = self.folder.appendingPathComponent("arguments")
            try FileManager.default.createDirectory(at: copilot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FakeCopilot.script.write(to: copilot, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)
            let state = home.appendingPathComponent("session-state/\(FakeCopilot.session)")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data((Line.userMessage("Fix the totals") + "\n" + Line.message("Fixed them.", at: 10) + "\n").utf8)
                .write(to: state.appendingPathComponent("events.jsonl"))
            environment = ["PATH": "/usr/bin:/bin", "HOME": self.folder.path].merging(base) { $1 }
            environment["COPILOT_HOME"] = home.path
            environment["FAKE_SERVER_LOG"] = log.path
            environment["FAKE_COPILOT_ARGUMENTS"] = arguments.path
            environment["FAKE_FORK_ID"] = FakeCopilot.fork
            environment["FAKE_FORK_GATE"] = self.folder.appendingPathComponent("fork-gate").path
            environment.merge(settings) { $1 }
        }

        /// Lets the stand-in answer a fork it was asked for with `FAKE_FORK=gated`, which it waits for until then.
        func openForkGate() throws {
            try Data().write(to: folder.appendingPathComponent("fork-gate"))
        }

        /// The fork's folder, as the stand-in makes it.
        var forkFolder: URL {
            home.appendingPathComponent("session-state/\(FakeCopilot.fork)")
        }

        /// The session's log.
        var sessionLog: URL {
            home.appendingPathComponent("session-state/\(FakeCopilot.session)/events.jsonl")
        }

        /// What the server was sent, in order.
        var messages: [[String: Any]] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
        }

        /// The methods BriefBar asked the server for, in order.
        var methods: [String] {
            messages.compactMap { $0["method"] as? String }
        }

        /// Waits until the server has been sent `method`, looking at its log up to 2,000 times, 10 ms apart: on
        /// `TestThreads`, since reading it that often in Swift's cooperative pool would hold up every other test.
        func waitUntilSent(_ method: String) async throws {
            try await withTaskExecutorPreference(TestThreads.shared) {
                for _ in 0..<2000 where !methods.contains(method) {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }

        /// The parameters of the first request for `method`.
        func parameters(of method: String) -> [String: Any]? {
            messages.first { $0["method"] as? String == method }?["params"] as? [String: Any]
        }

        func remove() {
            Cleanup.remove(folder)
        }
    }
}

/// Leftover forks in memory, with what was asked of them, in order: `keep <id>` and `drop <id>`.
actor RecordingLeftoverForks: LeftoverForks {
    private(set) var forks: [LeftoverFork] = []
    private(set) var calls: [String] = []

    func leftoverForks() -> [LeftoverFork] {
        forks
    }

    func keepLeftoverFork(_ fork: LeftoverFork) {
        calls.append("keep \(fork.id)")
        if !forks.contains(fork) { forks.append(fork) }
    }

    func dropLeftoverFork(_ fork: LeftoverFork) {
        calls.append("drop \(fork.id)")
        forks.removeAll { $0 == fork }
    }
}

/// Leftover forks whose task takes them on, and so no longer keeps them, right after they're first read: the list a
/// cleanup read then is stale.
actor TakenOnLeftoverForks: LeftoverForks {
    private var forks: [LeftoverFork]
    private var reads = 0

    init(_ forks: [LeftoverFork]) {
        self.forks = forks
    }

    func leftoverForks() -> [LeftoverFork] {
        defer {
            reads += 1
            if reads == 1 { forks = [] }
        }
        return forks
    }

    func keepLeftoverFork(_ fork: LeftoverFork) {
        if !forks.contains(fork) { forks.append(fork) }
    }

    func dropLeftoverFork(_ fork: LeftoverFork) {
        forks.removeAll { $0 == fork }
    }
}
