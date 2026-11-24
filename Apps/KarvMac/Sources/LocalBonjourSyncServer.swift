import Foundation
import Network
import KarvCore

/// Lightweight local HTTP/JSON server advertised over Bonjour (`_karv._tcp`)
/// so Karv on iPhone can discover this Mac automatically on Wi-Fi and pull live usage snapshots.
@MainActor
final class LocalBonjourSyncServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.cml.karv.bonjour.server")
    private var latestJSONData: Data = Data("{}".utf8)
    private(set) var isListening = false

    func start(initialSnapshot: KarvSnapshot) {
        update(snapshot: initialSnapshot)
        guard listener == nil else { return }

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let newListener = try NWListener(using: params)
            let deviceName = Host.current().localizedName ?? "KarvMac"
            newListener.service = NWListener.Service(name: deviceName, type: "_karv._tcp")

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isListening = true
                    case .failed, .cancelled:
                        self?.isListening = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            newListener.start(queue: queue)
            self.listener = newListener
        } catch {
            self.isListening = false
        }
    }

    func update(snapshot: KarvSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            latestJSONData = data
        }
    }

    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
            Task { @MainActor [weak self] in
                let payload = self?.latestJSONData ?? Data("{}".utf8)
                self?.sendHTTPResponse(payload: payload, on: connection)
            }
        }
    }

    private nonisolated func sendHTTPResponse(payload: Data, on connection: NWConnection) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(payload.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(payload)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
