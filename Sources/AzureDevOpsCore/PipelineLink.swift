import Foundation

/// A link to a pipeline, or to one of its runs, as Azure DevOps' pages have them:
/// `dev.azure.com/{org}/{project}/_build?definitionId={id}`, `…/_build/results?buildId={id}`, and the same on
/// `{org}.visualstudio.com[/DefaultCollection]/{project}/…`, with or without the scheme.
public struct PipelineLink: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// A pipeline, by its definition's ID.
        case pipeline(Int)
        /// One of its runs, by its build ID.
        case run(Int)
    }

    public var organization: String
    /// The project's name, as the link has it.
    public var project: String
    public var target: Target

    public init(organization: String, project: String, target: Target) {
        self.organization = organization
        self.project = project
        self.target = target
    }

    /// Nil for anything else, such as a pipeline's name.
    public init?(_ text: String) {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.contains(where: \.isWhitespace) else { return nil }
        if !string.lowercased().hasPrefix("http://") && !string.lowercased().hasPrefix("https://") {
            string = "https://" + string
        }
        guard let components = URLComponents(string: string), let host = components.host?.lowercased() else { return nil }
        var segments = components.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let organization: String
        if host == "dev.azure.com" {
            guard !segments.isEmpty else { return nil }
            organization = segments.removeFirst()
        } else if host.hasSuffix(".visualstudio.com") {
            organization = String(host.dropLast(".visualstudio.com".count))
            if segments.first?.lowercased() == "defaultcollection" { segments.removeFirst() }
        } else {
            return nil
        }
        // The project comes right before `_build`, which is right after it.
        guard OrganizationDiscovery.isValidName(organization), segments.count >= 2, segments[1].lowercased() == "_build",
              !segments[0].isEmpty
        else { return nil }
        let items = components.queryItems ?? []
        func number(_ name: String) -> Int? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        }
        let target: Target
        if let id = number("buildId") {
            target = .run(id)
        } else if let id = number("definitionId") {
            target = .pipeline(id)
        } else {
            return nil
        }
        self.init(organization: organization, project: segments[0], target: target)
    }
}
