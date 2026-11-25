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
    private var browserFailed = false
    private var activeEndpoint: NWEndpoint?
    private var pullInFlight = false
    private let queue = DispatchQueue(label: "com.cml.karv.bonjour.client")
    private weak var store: KarvSyncStore?

    private static let pullTimeout: TimeInterval = 8

    func start(store: KarvSyncStore) {
        self.store = store
        guard browser == nil else {
            pullNow()
            return
        }
        startBrowser()
    }

    /// iOS tears down local-network browsing while the app is suspended; the old
    /// browser can come back failed/cancelled and silently never report results again.
    func restartIfNeeded() {
        guard store != nil else { return }
        if browser == nil || browserFailed {
            browser?.cancel()
            browser = nil
            startBrowser()
        }
    }

    private func startBrowser() {
        browserFailed = false
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
                    self.activeEndpoint = nil
                    self.isConnectedToMac = false
                    self.statusMessage = "Looking for KarvMac on Wi-Fi..."
                }
            }
        }

        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
            Task { @MainActor [weak self] in
                // Ignore events from a browser we've already replaced (cancelling the old
                // one emits `.cancelled`, which must not flag the new one as failed).
                guard let self, let newBrowser, self.browser === newBrowser else { return }
                switch state {
                case .failed, .cancelled:
                    self.browserFailed = true
                    self.activeEndpoint = nil
                    self.isConnectedToMac = false
                    self.statusMessage = "Local network unavailable — retrying"
                    // Retry on our own instead of waiting for the next foreground.
                    try? await Task.sleep(for: .seconds(5))
                    self.restartIfNeeded()
                default:
                    break
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
        guard !pullInFlight else { return }
        pullInFlight = true

        statusMessage = "Syncing from \(discoveredMacName ?? "Mac")..."
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let req = Data("GET /snapshot.json HTTP/1.1\r\nHost: karv.local\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: req, completion: .contentProcessed { _ in
                    self?.receiveAll(on: connection, accumulated: Data())
                })
            case .failed, .waiting:
                // `.waiting` means unreachable right now; without cancelling, the
                // connection would sit there forever and block future pulls.
                connection.cancel()
                Task { @MainActor [weak self] in
                    self?.finishPull(success: false)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + Self.pullTimeout) { [weak self] in
            guard connection.state != .cancelled else { return }
            connection.cancel()
            Task { @MainActor [weak self] in
                self?.finishPull(success: false)
            }
        }
    }

    private func finishPull(success: Bool) {
        guard pullInFlight else { return }
        pullInFlight = false
        if !success {
            statusMessage = "Could not reach Mac — tap Sync to retry"
            KarvSyncHealth.recordFailure(.macWiFi, message: "Could not reach \(discoveredMacName ?? "Mac")")
        }
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
        guard let range = raw.range(of: separator),
              let headerText = String(data: raw[..<range.lowerBound], encoding: .utf8),
              headerText.hasPrefix("HTTP/1.1 200") || headerText.hasPrefix("HTTP/1.0 200") else {
            Task { @MainActor [weak self] in self?.finishPull(success: false) }
            return
        }
        let body = raw[range.upperBound...]
        guard let decoded = try? JSONDecoder().decode(KarvSnapshot.self, from: body) else {
            Task { @MainActor [weak self] in self?.finishPull(success: false) }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pullInFlight = false
            // Merge rather than overwrite: a fresher direct-OAuth Claude reading on the
            // phone must not be rolled back by the Mac's copy.
            self.store?.merge(decoded)
            KarvSyncHealth.recordSuccess(.macWiFi, message: "From \(decoded.sourceDeviceName)")
            WidgetCenter.shared.reloadAllTimelines()
            self.statusMessage = "Synced from \(decoded.sourceDeviceName)"
        }
    }
}
