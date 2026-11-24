import Foundation
import Network
import WidgetKit
import KarvCore

/// Automatically discovers KarvMac on the local Wi-Fi network via Bonjour (`_karv._tcp`)
/// and pulls the latest live KarvSnapshot directly over TCP/HTTP.
@MainActor
@Observable
final class MacBonjourSyncClient {
    private(set) var discoveredMacName: String?
    private(set) var statusMessage: String = "Searching for KarvMac on Wi-Fi..."
    private(set) var isConnectedToMac: Bool = false

    private var browser: NWBrowser?
    private var activeEndpoint: NWEndpoint?
    private let queue = DispatchQueue(label: "com.cml.karv.bonjour.client")
    private weak var store: KarvSyncStore?

    func start(store: KarvSyncStore) {
        self.store = store
        guard browser == nil else {
            pullNow()
            return
        }

        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_karv._tcp", domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: params)

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let first = results.first {
                    self.activeEndpoint = first.endpoint
                    if case let .service(name, _, _, _) = first.endpoint {
                        self.discoveredMacName = name
                        self.statusMessage = "Found \(name) on Wi-Fi"
                    } else {
                        self.statusMessage = "Found KarvMac on Wi-Fi"
                    }
                    self.isConnectedToMac = true
                    self.pullNow()
                } else {
                    self.isConnectedToMac = false
                    self.statusMessage = "Looking for KarvMac on Wi-Fi..."
                }
            }
        }

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed = state {
                    self?.statusMessage = "Local network unavailable"
                }
            }
        }

        newBrowser.start(queue: queue)
        self.browser = newBrowser
    }

    func pullNow() {
        guard let endpoint = activeEndpoint else {
            statusMessage = "Searching for KarvMac on Wi-Fi..."
            return
        }

        statusMessage = "Syncing from \(discoveredMacName ?? "Mac")..."
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let req = Data("GET /snapshot.json HTTP/1.1\r\nHost: karv.local\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: req, completion: .contentProcessed { _ in
                    self?.receiveAll(on: connection, accumulated: Data())
                })
            case .failed:
                connection.cancel()
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Could not reach Mac — tap Sync to retry"
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private nonisolated func receiveAll(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            var buffer = accumulated
            if let chunk {
                buffer.append(chunk)
            }

            if isComplete || error != nil {
                connection.cancel()
                self?.handleRawHTTP(buffer)
            } else {
                self?.receiveAll(on: connection, accumulated: buffer)
            }
        }
    }

    private nonisolated func handleRawHTTP(_ raw: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else { return }
        let body = raw[range.upperBound...]
        guard let decoded = try? JSONDecoder().decode(KarvSnapshot.self, from: body) else { return }

        Task { @MainActor [weak self] in
            guard let self, let store = self.store else { return }
            if store.preferences.useDemoMode {
                store.preferences.useDemoMode = false
            }
            store.publish(decoded)
            WidgetCenter.shared.reloadAllTimelines()
            self.statusMessage = "Synced from \(decoded.sourceDeviceName)"
        }
    }
}
