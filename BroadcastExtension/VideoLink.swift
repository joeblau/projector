import Foundation
import Network

/// TCP connection to the Mac's video service (Bonjour `_phoneprojv._tcp`), with in-flight byte accounting
/// so the encoder can drop frames instead of building latency.
final class VideoLink: @unchecked Sendable {
    var onReady: (() -> Void)?
    var log: ((String) -> Void)?

    private let queue = DispatchQueue(label: "projector.video.link")
    private var stopped = false
    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private let lock = NSLock()
    private var inflight = 0
    private var ready = false

    var inflightBytes: Int { lock.withLock { inflight } }
    var isReady: Bool { lock.withLock { ready } }

    /// Connects (or reconnects) to the Mac's video service at `e` (from the telemetry link).
    func connect(to e: NWEndpoint) {
        queue.async {
            if e == self.endpoint, self.connection != nil { return }
            self.connect(e)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel(); self.connection = nil
            self.lock.withLock { self.ready = false; self.inflight = 0 }
        }
    }

    func send(type: VideoMessageType, payload: Data) {
        guard let c = connection, isReady else { return }
        // One buffer per message: header + payload can never be split or reordered.
        var message = Data(capacity: payload.count + 5)
        withUnsafeBytes(of: UInt32(payload.count + 1).littleEndian) { message.append(contentsOf: $0) }
        message.append(type.rawValue)
        message.append(payload)
        let total = message.count
        lock.withLock { inflight += total }
        c.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.withLock { self.inflight -= total }
            if let error { self.log?("video send error: \(error)") }
        })
    }

    private func connect(_ e: NWEndpoint) {
        connection?.cancel()
        endpoint = e
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        let c = NWConnection(to: e, using: params)
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, c === self.connection else { return }
            switch s {
            case .ready:
                self.lock.withLock { self.ready = true; self.inflight = 0 }
                self.log?("video tcp ready to \(e) via \(c.currentPath?.availableInterfaces.first?.name ?? "?")")
                self.onReady?()
            case .waiting(let err):
                self.log?("video tcp waiting (\(e)): \(err)")
                c.cancel()
            case .failed, .cancelled:
                if case let .failed(err) = s { self.log?("video tcp failed (\(e)): \(err)") }
                self.lock.withLock { self.ready = false }
                self.connection = nil
                // Mac app restarted or Wi-Fi blipped: retry the same host.
                if !self.stopped {
                    self.queue.asyncAfter(deadline: .now() + 1) {
                        if self.connection == nil, !self.stopped { self.log?("video tcp retry \(e)"); self.connect(e) }
                    }
                }
            default: break
            }
        }
        c.start(queue: queue)
        connection = c
    }
}
