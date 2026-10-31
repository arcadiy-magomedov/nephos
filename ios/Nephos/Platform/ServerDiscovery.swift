import Foundation
import Network
import Observation

@MainActor @Observable
final class ServerDiscovery {
    private(set) var servers: [ServerAdvertisement] = []
    private(set) var isSearching = false
    private(set) var message: String?
    private(set) var hasOmittedResults = false
    private var browser: NWBrowser?
    private var generation = UUID()

    func start() {
        stop()
        message = nil
        isSearching = true
        let generation = self.generation
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_nephos._tcp", domain: "local."), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready: self.message = nil
                case .waiting(let error), .failed(let error):
                    self.servers = []
                    self.message =
                        "Local discovery is unavailable. Check Wi-Fi and Local Network permission in iPhone Settings, then try again. You can still enter an address. (\(error))"
                    if case .failed = state { self.stop() }
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                var found: [String: ServerAdvertisement] = [:]
                var omitted = false
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint,
                        case .bonjour(let record) = result.metadata,
                        let versionData = record.getEntry(for: "v")?.data,
                        let addressData = record.getEntry(for: "url")?.data,
                        let version = String(data: versionData, encoding: .utf8),
                        let address = String(data: addressData, encoding: .utf8)
                    else {
                        omitted = true
                        continue
                    }
                    do {
                        let server = try ServerAdvertisement(name: name, version: version, address: address)
                        if let existing = found[server.id], existing.name < server.name { continue }
                        found[server.id] = server
                    } catch {
                        omitted = true
                    }
                }
                self.servers = Array(found.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }.prefix(32))
                self.hasOmittedResults = omitted || found.count > 32
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        browser?.cancel()
        browser = nil
        isSearching = false
        servers = []
        hasOmittedResults = false
    }
}
