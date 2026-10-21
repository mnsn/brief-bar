import Foundation

/// What BriefBar can show you, from one app or service. Every source is off until you turn it on.
public enum SourceID: String, CaseIterable, Codable, Sendable, Identifiable {
    case teams
    case azureDevOps
    case copilot

    public var id: String { rawValue }
}

/// What a source needs before it can show anything.
public enum Requirement: String, Codable, Sendable {
    /// To read Notification Center's database. macOS has no prompt for it: you add BriefBar to the list in
    /// System Settings, once, and every source that reads that database uses it.
    case fullDiskAccess
    /// The Azure CLI, signed in with `az login`.
    case azureCLI
    /// Permission to show notifications.
    case notifications
}

/// One list that a source shows, such as Teams' group chats. Each menu-bar item shows one or more.
public struct SectionID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The source it belongs to, or nil for one this version doesn't know.
    public var source: SourceID? {
        rawValue.split(separator: ".", maxSplits: 1).first.flatMap { SourceID(rawValue: String($0)) }
    }

    public var description: String { rawValue }

    public static let teamsChats = SectionID(rawValue: "teams.chats")
    public static let teamsGroupChats = SectionID(rawValue: "teams.groupChats")
    public static let azureDevOpsPullRequests = SectionID(rawValue: "azureDevOps.pullRequests")
    public static let copilotSessions = SectionID(rawValue: "copilot.sessions")
}

/// That you turned a source on, having seen what it reads.
public struct SourceConsent: Codable, Equatable, Sendable {
    /// The version of the source's description of what it reads, when you turned it on.
    public var version: Int
    public var date: Date

    public init(version: Int, date: Date) {
        self.version = version
        self.date = date
    }
}

public enum SourceState: Equatable, Sendable {
    case off
    case on
    /// You turned it on, but it reads more now than what you saw then, so it waits until you've seen what it
    /// reads now.
    case needsReview
}

/// The sources you turned on, saved in BriefBar's preferences.
///
/// macOS asks for some permissions only once for the whole app (Full Disk Access, notifications), so turning
/// a source on here is the only consent it gets. A source is on only while this holds your consent to what it
/// reads: a missing or unreadable record, a source that an update adds, or one this version doesn't know is
/// off. Nothing but `turnOn` adds consent.
public struct SourceChoices: Codable, Equatable, Sendable {
    /// By source ID. IDs that this version doesn't know are kept as they are, for a later version, and ignored.
    public private(set) var consents: [String: SourceConsent]

    public init() {
        consents = [:]
    }

    /// Whether the source is on, given the version of its description of what it reads.
    public func state(of source: SourceID, version: Int) -> SourceState {
        guard let consent = consents[source.rawValue] else { return .off }
        return consent.version >= version ? .on : .needsReview
    }

    /// Turns the source on, with your consent to the version of its description you saw.
    public mutating func turnOn(_ source: SourceID, version: Int, at date: Date = Date()) {
        consents[source.rawValue] = SourceConsent(version: version, date: date)
    }

    public mutating func turnOff(_ source: SourceID) {
        consents[source.rawValue] = nil
    }

    // MARK: Saving

    public static let defaultsKey = "sources"

    /// What's saved, or nothing on when there's nothing saved or it can't be read.
    public static func load(from defaults: UserDefaults) -> SourceChoices {
        guard let data = defaults.data(forKey: defaultsKey),
              let choices = try? JSONDecoder().decode(SourceChoices.self, from: data)
        else { return SourceChoices() }
        return choices
    }

    public func save(to defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
