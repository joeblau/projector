import Foundation
import Network

/// Finds the Mac via Bonjour (falls back to the MacHost Info.plist value) and sends UDP datagrams to it.
final class MacLink: @unchecked Sendable {
    enum State: Equatable { case searching, connecting(String), ready(String), failed(String) }

    var onStateChange: ((State) -> Void)?
    /// Called once the UDP path is up with the Mac's endpoint for the video channel: its resolved
    /// host on the video port when known, otherwise the Bonjour service itself.
    var onVideoEndpoint: ((NWEndpoint) -> Void)?
    var source: TelemetrySource = .app

    /// Ships a debug line to the Mac's log.
    func log(_ message: String) { send(encodeLog(message, source: source)) }
    private(set) var state: State = .searching { didSet { if state != oldValue { onStateChange?(state) } } }

    private let queue = DispatchQueue(label: "projector.link")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var currentEndpoint: NWEndpoint?

    func start() {
        queue.async { self.startBrowsing() }
        // Fallback for networks that block multicast DNS.
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.connection == nil,
                  let host = Bundle.main.object(forInfoDictionaryKey: "MacHost") as? String, !host.isEmpty else { return }
            self.connect(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Wire.port)!), name: host)
        }
    }

    func stop() {
        queue.async {
            self.browser?.cancel(); self.browser = nil
            self.connection?.cancel(); self.connection = nil
            self.currentEndpoint = nil
        }
    }

    func send(_ data: Data) {
        guard let connection, connection.state == .ready else { return }
        connection.send(content: data, completion: .idempotent)
    }

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjour(type: Wire.serviceType, domain: nil), using: .udp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            // Stay on the current Mac if it's still advertised; otherwise take the first one.
            if let current = self.currentEndpoint, results.contains(where: { $0.endpoint == current }) { return }
            guard let first = results.first else { return }
            var name = "Mac"
            if case let .service(n, _, _, _) = first.endpoint { name = n }
            self.connect(to: first.endpoint, name: name)
        }
        b.stateUpdateHandler = { [weak self] s in
            if case let .failed(err) = s { self?.state = .failed("Browse: \(err.localizedDescription)") }
            if case let .waiting(err) = s { self?.state = .failed("Local Network: \(err.localizedDescription)") }
        }
        b.start(queue: queue)
        browser = b
    }

    private func connect(to endpoint: NWEndpoint, name: String) {
        connection?.cancel()
        currentEndpoint = endpoint
        state = .connecting(name)
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo   // lowest-latency Wi-Fi access category
        let c = NWConnection(to: endpoint, using: params)
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, c === self.connection else { return }
            switch s {
            case .ready:
                self.state = .ready(name)
                let port = NWEndpoint.Port(rawValue: Wire.videoPort)!
                let remote = c.currentPath?.remoteEndpoint
                let iface = c.currentPath?.availableInterfaces.first?.name ?? "?"
                if case let .hostPort(host, _)? = remote {
                    self.onVideoEndpoint?(.hostPort(host: host, port: port))
                } else {
                    self.onVideoEndpoint?(endpoint)   // resolves to the same host, port 47800 (TCP listens there too)
                }
                self.queue.asyncAfter(deadline: .now() + 0.3) {
                    self.log("udp ready via \(iface), remote=\(remote.map { "\($0)" } ?? "nil")")
                }
            case .waiting(let e):
                // e.g. the cable was pulled: start over so Bonjour can resolve the Wi-Fi address.
                self.state = .failed("waiting: \(e.localizedDescription)")
                self.reconnectSoon(c)
            case .failed(let e):
                self.state = .failed(e.localizedDescription)
                self.reconnectSoon(c)
            default: break
            }
        }
        // Interface changes (USB <-> Wi-Fi) don't always fail a UDP flow; treat loss of viability as a reconnect.
        c.viabilityUpdateHandler = { [weak self, weak c] viable in
            guard let self, let c, !viable else { return }
            self.queue.asyncAfter(deadline: .now() + 1) { if c === self.connection, c.state != .ready || c.currentPath?.status != .satisfied { self.reconnectSoon(c) } }
        }
        c.betterPathUpdateHandler = { [weak self, weak c] better in
            guard let self, let c, better else { return }
            self.reconnectSoon(c)
        }
        c.start(queue: queue)
        connection = c
    }

    private func reconnectSoon(_ c: NWConnection) {
        guard c === connection else { return }
        let endpoint = currentEndpoint
        var name = "Mac"
        if case let .service(n, _, _, _)? = endpoint { name = n }
        c.cancel()
        connection = nil
        queue.asyncAfter(deadline: .now() + 0.5) {
            guard self.connection == nil else { return }
            if let endpoint { self.connect(to: endpoint, name: name) } else { self.currentEndpoint = nil }
        }
    }
}
