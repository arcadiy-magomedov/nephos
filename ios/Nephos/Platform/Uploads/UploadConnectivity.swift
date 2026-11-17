import Network
import Observation

@MainActor
@Observable
final class UploadConnectivity {
    private(set) var connected = false
    private(set) var wiFi = false
    private(set) var hasPath = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    init(changed: @escaping @MainActor @Sendable () -> Void) {
        monitor.pathUpdateHandler = { path in
            let connected = path.status == .satisfied
            let wiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                self?.connected = connected
                self?.wiFi = wiFi
                self?.hasPath = true
                changed()
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.nephos.ios.upload-connectivity"))
    }

    deinit { monitor.cancel() }

    func permits(_ policy: UploadPolicy) -> Bool {
        connected && (policy == .allNetworks || policy == .wiFiOnly && wiFi)
    }
}
