import Foundation

public enum InterfaceOption: String, CaseIterable, Sendable {
    case compactBriefs
    case quietAppearance
    case readableRows
    case compactMenuBar
    case clearerStates
    case visibleActions
    case simpleLayoutControls

    public var defaultsKey: String { "interface.\(rawValue)" }
}

/// Presentation choices only: none are enabled implicitly or stored in a source's settings or layout.
public struct InterfaceOptions: Equatable, Sendable {
    private var enabled: Set<InterfaceOption>

    public init(enabled: Set<InterfaceOption> = []) {
        self.enabled = enabled
    }

    public subscript(option: InterfaceOption) -> Bool {
        get { enabled.contains(option) }
        set {
            if newValue {
                enabled.insert(option)
            } else {
                enabled.remove(option)
            }
        }
    }

    public var compactBriefs: Bool { self[.compactBriefs] }
    public var quietAppearance: Bool { self[.quietAppearance] }
    public var readableRows: Bool { self[.readableRows] }
    public var compactMenuBar: Bool { self[.compactMenuBar] }
    public var clearerStates: Bool { self[.clearerStates] }
    public var visibleActions: Bool { self[.visibleActions] }
    public var simpleLayoutControls: Bool { self[.simpleLayoutControls] }

    public static func load(from defaults: some SettingsStorage) -> InterfaceOptions {
        InterfaceOptions(enabled: Set(InterfaceOption.allCases.filter { defaults.bool(forKey: $0.defaultsKey) }))
    }

    public func save(to defaults: some SettingsStorage) {
        for option in InterfaceOption.allCases {
            defaults.set(self[option], forKey: option.defaultsKey)
        }
    }

    /// A temporary presentation of already-visible sections. Saved item IDs, hidden sections and order survive.
    public func menuBarItems(_ items: [SectionLayout.Item]) -> [SectionLayout.Item] {
        guard compactMenuBar, !items.isEmpty else { return items }
        return [SectionLayout.Item(id: Self.compactMenuBarID, sections: items.flatMap(\.sections))]
    }

    public static let compactMenuBarID = "briefbar.compact"
}
