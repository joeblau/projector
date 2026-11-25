import Foundation
import Network

/// Advertises `_phoneproj._udp` over Bonjour and feeds every datagram into the hub.
final class TelemetryReceiver: @unchecked Sendable {
    private let hub: TelemetryHub
    private let queue = DispatchQueue(label: "projector.receiver", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(hub: TelemetryHub) { self.hub = hub }

    func start() {
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Wire.port)!)
            l.service = NWListener.Service(name: Host.current().localizedName ?? "Projector Mac", type: Wire.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.hub.setListenerState("Listening on :\(Wire.port)")
                case .failed(let e): self?.hub.setListenerState("Listener failed: \(e.localizedDescription)")
                case .waiting(let e): self?.hub.setListenerState("Waiting: \(e.localizedDescription)")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            hub.setListenerState("Listener error: \(error.localizedDescription)")
        }
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.queue.async { self?.connections[id] = nil }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = WireDecoder.decode(data) { self.hub.ingest(packet) }
            if error == nil { self.receive(on: conn) }
        }
    }
}
