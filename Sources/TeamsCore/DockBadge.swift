import BriefBarCore
import Foundation
import NotificationCenterDB

/// Teams' dock badge, as `lsappinfo info -long -only StatusLabel -app com.microsoft.teams2` reports it:
/// `"StatusLabel"={ "label"="3" }` while there's a badge; `"label"=kCFNULL`, or only the app's
/// `"LSASN"=…` line, when the app runs without one; and nothing at all when the app isn't running.
/// Without `-long`, macOS 27's `lsappinfo` leaves `StatusLabel` out, so no badge would ever show.
public enum DockBadge: Sendable, Equatable {
    case noBadge
    case count(Int)
    /// A badge that isn't a number, such as a dot.
    case mark

    public var isClear: Bool {
        switch self {
        case .noBadge: return true
        case .count(let count): return count <= 0
        case .mark: return false
        }
    }

    /// Nil when the output says nothing about the badge, as when the app isn't running, or in a format
    /// without `StatusLabel`: that's no news about the badge.
    public static func parse(lsappinfo output: String) -> DockBadge? {
        if let match = output.firstMatch(of: /"label"\s*=\s*"([^"]*)"/) {
            let label = match.1.trimmingCharacters(in: .whitespaces)
            if label.isEmpty { return .noBadge }
            if let count = Int(label) { return .count(count) }
            return .mark
        }
        // The app runs (it has an ASN), without a badge, or with one it took away (`kCFNULL`).
        if output.contains("\"StatusLabel\"=") || output.contains("\"LSASN\"=") { return .noBadge }
        return nil
    }

    /// The `lsappinfo` arguments that read an app's badge.
    public static func lsappinfoArguments(bundleIdentifier: String) -> [String] {
        ["info", "-long", "-only", "StatusLabel", "-app", bundleIdentifier]
    }

    /// Reads an app's dock badge with `lsappinfo`, which needs no permission. Nil when there's nothing
    /// to read, as when the app isn't running. Waits for `lsappinfo`, so call it off the main thread.
    public static func read(bundleIdentifier: String) -> DockBadge? {
        guard let result = try? ProcessRunner().runAndWait(
            URL(fileURLWithPath: "/usr/bin/lsappinfo"), arguments: lsappinfoArguments(bundleIdentifier: bundleIdentifier),
            timeout: 10
        ), result.status == 0 else { return nil }
        return parse(lsappinfo: String(decoding: result.stdout, as: UTF8.self))
    }
}

/// Tells when Teams' dock badge cleared. Only a badge that was there, then stayed gone for
/// `confirmation`, in the same Teams process, counts. No badge right after Teams starts, no reading at
/// all, or a badge that's back within `confirmation` (as it might be while Teams reloads) says nothing.
public struct DockBadgeTracker: Sendable {
    /// How long a badge must stay gone to count.
    public let confirmation: TimeInterval
    private var last: DockBadge?
    private var process: Int32?
    /// When the first reading without the badge was taken, until that's reported or the badge is back.
    private var clearedAt: Date?

    public init(confirmation: TimeInterval = 10) {
        self.confirmation = confirmation
    }

    /// Takes in a reading taken at `date` (nil when there was nothing to read) from the Teams process
    /// `process`. Once the badge has stayed gone for `confirmation`, returns when it was first seen gone:
    /// everything delivered until then was read. Each badge that clears is reported once.
    public mutating func update(_ badge: DockBadge?, process: Int32, at date: Date) -> Date? {
        guard let badge else {
            reset()
            return nil
        }
        if self.process != process {
            reset()
            self.process = process
        }
        defer { last = badge }
        guard badge.isClear else {
            clearedAt = nil
            return nil
        }
        if let last, !last.isClear {
            clearedAt = date
        }
        guard let cleared = clearedAt, date.timeIntervalSince(cleared) >= confirmation else { return nil }
        clearedAt = nil
        return cleared
    }

    /// Teams started or quit: its badge starts over.
    public mutating func reset() {
        last = nil
        process = nil
        clearedAt = nil
    }
}
