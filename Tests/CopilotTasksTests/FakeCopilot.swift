import Foundation
@testable import CopilotTasks

/// A stand-in for the Copilot CLI, as the real one behaves for forks and side questions. As `copilot --headless --stdio`,
/// it answers BriefBar's JSON-RPC requests, each after a `Content-Length` header, as the CLI's server does: connect,
/// sessions.fork, session.resume, session.ui.ephemeralQuery and session.delete, and nothing else; while it answers a
/// question, it says something unasked and asks something of its own, as the server does. Each message it gets goes to
/// `$FAKE_SERVER_LOG`, one a line. What it answers follows `FAKE_VERSION`, `FAKE_FORK` (`unsupported`, `fails`, `hang`, or
/// `late`, a second late),
/// `FAKE_FORK_ID` and `FAKE_ANSWER` (`hang`, `exit`, `signed-out`, or the answer). As `copilot -p`, it writes its
/// arguments to `$FAKE_COPILOT_ARGUMENTS` and a session log ending with the task done, as `CopilotLauncherTests`' does.
enum FakeCopilot {
    static let script = #"""
        #!/bin/sh
        if [ "$1" != "--headless" ]; then
          printf '%s\n' "$@" > "$FAKE_COPILOT_ARGUMENTS"
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
                late) sleep 1; answer "$id" "{\"sessionId\":\"$FAKE_FORK_ID\",\"name\":\"fork\"}" ;;
                *) answer "$id" "{\"sessionId\":\"$FAKE_FORK_ID\",\"name\":\"fork\"}" ;;
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
            session.delete) answer "$id" '{"success":true}' ;;
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
            environment.merge(settings) { $1 }
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

        /// The parameters of the first request for `method`.
        func parameters(of method: String) -> [String: Any]? {
            messages.first { $0["method"] as? String == method }?["params"] as? [String: Any]
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
