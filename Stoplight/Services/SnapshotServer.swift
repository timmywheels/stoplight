import Foundation
import Network
import OSLog
import StoplightCore

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "SnapshotServer")

/// Serves the current snapshot to the widget over loopback (US-007).
///
/// Why: the sandboxed widget can only read its own container or an App Group container. App Groups
/// need the group in the provisioning profile (Personal teams and ad-hoc builds can't), and writing
/// into the widget's container triggers macOS's "access data from other apps" prompt. A loopback
/// HTTP GET needs neither: the widget only requires the `network.client` sandbox entitlement.
/// Binds 127.0.0.1 only. Payload is the same non-secret prs.json.
@MainActor
final class SnapshotServer {
    static let port: UInt16 = SharedStore.loopbackPort
    private var listener: NWListener?
    private var body = Data("{}".utf8)

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { state in
                if case .failed(let err) = state { log.error("listener failed: \(String(describing: err), privacy: .public)") }
            }
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                // Read whatever the request is, answer with the snapshot, close. Both callbacks run on .main.
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
                    let body = MainActor.assumeIsolated { self?.body }
                    guard let body else { conn.cancel(); return }
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
                    conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            l.start(queue: .main)
            listener = l
            log.notice("serving snapshot on 127.0.0.1:\(Self.port)")
        } catch {
            log.error("could not start: \(String(describing: error), privacy: .public)")
        }
    }

    func update(_ data: Data) { body = data }
}
