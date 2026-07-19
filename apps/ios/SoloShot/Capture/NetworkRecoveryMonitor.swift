import Foundation
import Network

protocol NetworkRecoveryMonitoring: AnyObject, Sendable {
    func start(onReachable: @escaping @Sendable () -> Void)
    func cancel()
}

final class SystemNetworkRecoveryMonitor: NetworkRecoveryMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.soloshot.network-recovery")

    func start(onReachable: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            onReachable()
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}
