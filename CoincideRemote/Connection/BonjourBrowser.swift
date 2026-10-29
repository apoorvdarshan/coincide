import CoincideRemoteKit
import Foundation
import Network
import Observation

/// A Mac running Coincide with Remote turned on, found on the local network.
struct DiscoveredMac: Hashable, Identifiable {
    var serverID: String
    var name: String
    var endpoint: NWEndpoint

    var id: String { serverID.isEmpty ? name : serverID }
}

/// Browses for `_coincide._tcp` on the local network. The first browse asks for Local Network permission.
@MainActor
@Observable
final class BonjourBrowser {
    private(set) var macs: [DiscoveredMac] = []
    /// Local Network permission was refused, so nothing can be found.
    private(set) var isDenied = false
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteProtocol.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredMac? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var serverID = ""
                if case .bonjour(let record) = result.metadata { serverID = record["id"] ?? "" }
                return DiscoveredMac(serverID: serverID, name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.macs = found.sorted { $0.name < $1.name } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed(let error), .waiting(let error):
                    if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ { self?.isDenied = true }
                case .ready:
                    self?.isDenied = false
                default:
                    break
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    func mac(serverID: String) -> DiscoveredMac? { macs.first { $0.serverID == serverID } }
}
