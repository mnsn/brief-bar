import Foundation
import Network

/// Tells when the Mac goes online or offline, so Azure DevOps is read again as soon as it's back.
public final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "BriefBar.AzureDevOps.network", qos: .utility)

    /// - Parameter onChange: whether the Mac is online, on a queue of the monitor's own.
    public init(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(path.status == .satisfied) }
    }

    public func start() {
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }
}
