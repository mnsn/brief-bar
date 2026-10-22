import Foundation

/// What BriefBar and its updater (Sources/BriefBarUpdater) tell each other: one JSON object per line, through the
/// updater's standard input (requests) and output (events). The updater holds Sparkle and none of BriefBar's
/// privacy permissions, so BriefBar takes nothing from it but these few fields, and only shows them.
public struct UpdaterMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// To the updater: Check for Updates…, or bring the update that's waiting to the front.
        case check
        /// To the updater: whether to check for updates automatically (`flag`).
        case setAutomaticallyChecks
        /// From the updater, run with `--hello`: it started, with Sparkle `version` loaded from `path`.
        case hello
        /// From the updater: whether a check can start now (`canCheck`), and whether it checks automatically.
        case state
        /// From the updater: a scheduled check found `version`, which waits for your attention.
        case pending
        /// From the updater: the update that waited has your attention now, or is gone.
        case attended
    }

    public var kind: Kind
    public var flag: Bool?
    public var canCheck: Bool?
    public var automaticallyChecks: Bool?
    public var version: String?
    public var path: String?

    public init(
        _ kind: Kind, flag: Bool? = nil, canCheck: Bool? = nil, automaticallyChecks: Bool? = nil,
        version: String? = nil, path: String? = nil
    ) {
        self.kind = kind
        self.flag = flag
        self.canCheck = canCheck
        self.automaticallyChecks = automaticallyChecks
        self.version = version
        self.path = path
    }

    /// The message as one line, without the newline. JSON escapes any line break in a string.
    public var line: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// A line from the other side, or nil if it isn't a message this version knows.
    public init?(line: Data) {
        guard let message = try? JSONDecoder().decode(UpdaterMessage.self, from: line) else { return nil }
        self = message
    }

    /// `version`, if it looks like one, to show: up to 32 letters, digits, dots, plus and minus signs.
    public var displayVersion: String? {
        guard let version, !version.isEmpty, version.count <= 32,
              version.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".+-".unicodeScalars.contains($0)) })
        else { return nil }
        return version
    }
}
