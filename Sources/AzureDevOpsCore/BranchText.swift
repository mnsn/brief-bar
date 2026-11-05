import Foundation

/// Text that may name branches, such as what the lists say a pull request merged into or where its conflicts are: kept as
/// its parts, each branch apart, so that what writes it out names each branch its way, as agents get them, say, in single
/// quotes when a shell would read something in them (`QuotedText.commandWord`), rather than by finding them in the text.
/// Written as a string, with `\(branch:)` for each branch: `"Merged into \(branch: pr.targetBranch)"`.
public struct BranchText: Sendable, Equatable, ExpressibleByStringInterpolation {
    public enum Part: Sendable, Equatable {
        case text(String)
        case branch(String)
    }

    public var parts: [Part]

    /// Text that names no branch.
    public init(_ text: String) {
        parts = text.isEmpty ? [] : [.text(text)]
    }

    public init(stringLiteral text: String) {
        self.init(text)
    }

    public init(stringInterpolation: StringInterpolation) {
        parts = stringInterpolation.parts
    }

    /// Its text, with each branch written as `naming` writes it: as it is by default, as the lists show it.
    public func text(naming: (String) -> String = { $0 }) -> String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .branch(let name): naming(name)
            }
        }.joined()
    }

    public static func + (lhs: BranchText, rhs: BranchText) -> BranchText {
        var joined = lhs
        joined.parts += rhs.parts
        return joined
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var parts: [Part] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            if !literal.isEmpty { parts.append(.text(literal)) }
        }

        /// Text that names no branch, such as how many pipelines run.
        public mutating func appendInterpolation(_ text: String) {
            if !text.isEmpty { parts.append(.text(text)) }
        }

        /// A branch, by its name.
        public mutating func appendInterpolation(branch name: String) {
            parts.append(.branch(name))
        }
    }
}

extension BranchText: Codable {
    /// As its text, with its branches as they are, as the lists show it: a pull request's detail is a line in what `--json`
    /// writes, as it always was (`PRSnapshot.CodingKeys`). Read back, it's text that names no branch.
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text())
    }
}
