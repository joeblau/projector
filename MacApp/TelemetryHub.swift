import Foundation
import QuartzCore
import simd

/// Thread-safe store for incoming telemetry. Written at ~100 Hz from the network queue,
/// read every frame by the renderer and at 30 Hz by the HUD.
final class TelemetryHub: @unchecked Sendable {
    struct SourceState {
        var lastMotion: MotionPacket?
        var lastMotionAt: CFTimeInterval = 0
        var lastStatus: StatusPacket?
        var packetTimes: [CFTimeInterval] = []   // receive times in the last second
        var lastSeq: UInt32 = 0
        var dropped: Int = 0
    }

    struct Snapshot {
        var listenerState = "Starting…"
        var activeSource: TelemetrySource?
        var connected = false
        var motion: MotionPacket?
        var status: StatusPacket?
        var rateHz = 0
        var dropped = 0
        var latencyMs: Double?
        var rotationHistory: [SIMD3<Float>] = []
        var accelHistory: [SIMD3<Float>] = []
        var displayOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var bodyName: String?
        var smoothing = SmoothingLevel.light
    }

    static let historyLength = 400   // 4 s at 100 Hz
    static let staleAfter: CFTimeInterval = 0.5

    private let lock = NSLock()
    private var sources: [TelemetrySource: SourceState] = [:]
    private var listenerState = "Starting…"
    private var rotationHistory: [SIMD3<Float>] = []
    private var accelHistory: [SIMD3<Float>] = []
    private var recenterOffset = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var smoothing = SmoothingLevel.light
    private var attitudeFilter = OneEuroQuaternion()
    private var joltFilter = JoltFilter()
    private var filteredAttitude: simd_quatf?
    private var filteredJolt = SIMD3<Float>.zero
    private var filteredSource: TelemetrySource?
    private var wantsRecenter = true

    /// CoreMotion reference frame is Z-up; RealityKit is Y-up. Rotate -90° about X: (x, y, z) -> (x, z, -y).
    private static let coreMotionToWorld = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))

    func setListenerState(_ s: String) { lock.withLock { listenerState = s } }

    private var bodyName: String?
    func setBodyName(_ n: String) { lock.withLock { bodyName = n } }

    /// Name of the device currently streaming (used to pick the matching USB capture device).
    func deviceName() -> String? {
        lock.withLock {
            if let src = activeSourceLocked(now: CACurrentMediaTime()), let n = sources[src]?.lastStatus?.deviceName { return n }
            return sources.values.compactMap(\.lastStatus?.deviceName).first
        }
    }

    func ingest(_ packet: DecodedPacket) {
        let now = CACurrentMediaTime()
        lock.withLock {
            switch packet {
            case .motion(let m):
                var s = sources[m.source] ?? SourceState()
                // A long silence means a new session: recenter on the first sample.
                if now - s.lastMotionAt > 2 && activeSourceLocked(now: now) == nil { wantsRecenter = true }
                if s.lastSeq != 0, m.seq > s.lastSeq + 1, m.seq - s.lastSeq < 1000 { s.dropped += Int(m.seq - s.lastSeq - 1) }
                s.lastSeq = m.seq
                s.lastMotion = m
                s.lastMotionAt = now
                s.packetTimes.append(now)
                s.packetTimes.removeAll { now - $0 > 1 }
                sources[m.source] = s

                if activeSourceLocked(now: now) == m.source {
                    // Switching between app and broadcast streams restarts the filters (different clocks).
                    if filteredSource != m.source { attitudeFilter.reset(); joltFilter.reset(); filteredSource = m.source }
                    filteredAttitude = attitudeFilter.filter(m.attitude, time: m.timestamp,
                                                             angularSpeed: simd_length(m.rotationRate), level: smoothing)
                    filteredJolt = joltFilter.filter(m.userAcceleration, time: m.timestamp, level: smoothing)
                    rotationHistory.append(m.rotationRate)
                    accelHistory.append(m.userAcceleration)
                    if rotationHistory.count > Self.historyLength { rotationHistory.removeFirst(rotationHistory.count - Self.historyLength) }
                    if accelHistory.count > Self.historyLength { accelHistory.removeFirst(accelHistory.count - Self.historyLength) }
                    if wantsRecenter { recenterLocked(on: m); wantsRecenter = false }
                }
            case .log(let src, let msg):
                NSLog("[phone:\(src.label)] \(msg)")
            case .status(let st):
                var s = sources[st.source] ?? SourceState()
                s.lastStatus = st
                sources[st.source] = s
            }
        }
    }

    /// Model identifier of the most recently heard-from device (e.g. "iPhone18,4").
    func modelIdentifier() -> String? {
        lock.withLock {
            let now = CACurrentMediaTime()
            if let src = activeSourceLocked(now: now), let id = sources[src]?.lastStatus?.modelIdentifier { return id }
            return sources.values.compactMap(\.lastStatus?.modelIdentifier).first
        }
    }

    /// Latest gravity vector in the device frame (g), if streaming.
    func gravity() -> SIMD3<Float>? {
        lock.withLock {
            guard let src = activeSourceLocked(now: CACurrentMediaTime()) else { return nil }
            return sources[src]?.lastMotion?.gravity
        }
    }

    func requestRecenter() { lock.withLock { wantsRecenter = true } }

    /// Orientation for the 3D phone, in RealityKit world space.
    func targetOrientation() -> simd_quatf? {
        lock.withLock {
            guard let src = activeSourceLocked(now: CACurrentMediaTime()),
                  let m = sources[src]?.lastMotion else { return nil }
            return recenterOffset * Self.worldOrientation(filteredAttitude ?? m.attitude)
        }
    }

    var smoothingLevel: SmoothingLevel {
        get { lock.withLock { smoothing } }
        set { lock.withLock { smoothing = newValue; attitudeFilter.reset(); joltFilter.reset() } }
    }

    /// User acceleration rotated into world space (g), for the subtle "jolt" offset.
    func worldUserAcceleration() -> SIMD3<Float> {
        lock.withLock {
            guard let src = activeSourceLocked(now: CACurrentMediaTime()),
                  let m = sources[src]?.lastMotion else { return .zero }
            return (recenterOffset * Self.worldOrientation(filteredAttitude ?? m.attitude)).act(filteredJolt)
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            let now = CACurrentMediaTime()
            var snap = Snapshot()
            snap.listenerState = listenerState
            snap.bodyName = bodyName
            snap.smoothing = smoothing
            snap.rotationHistory = rotationHistory
            snap.accelHistory = accelHistory
            guard let src = activeSourceLocked(now: now), let s = sources[src] else {
                // Remember the last device we saw so the HUD can say who disconnected.
                snap.status = sources.values.compactMap(\.lastStatus).first
                return snap
            }
            snap.activeSource = src
            snap.connected = true
            snap.motion = s.lastMotion
            snap.status = s.lastStatus
            snap.rateHz = s.packetTimes.filter { now - $0 <= 1 }.count
            snap.dropped = s.dropped
            if let m = s.lastMotion {
                let ms = (Date().timeIntervalSince1970 - m.sentAt) * 1000
                snap.latencyMs = (ms > -50 && ms < 2000) ? max(ms, 0) : nil   // clocks may be unsynced
                snap.displayOrientation = recenterOffset * Self.worldOrientation(filteredAttitude ?? m.attitude)
            }
            return snap
        }
    }

    // MARK: - Private (call with lock held)

    /// Prefer the broadcast extension (works over any app); fall back to the foreground app.
    private func activeSourceLocked(now: CFTimeInterval) -> TelemetrySource? {
        for src in [TelemetrySource.broadcast, .app] {
            if let s = sources[src], now - s.lastMotionAt < Self.staleAfter { return src }
        }
        return nil
    }

    /// Yaw-only recenter: the screen faces the camera, without fighting real pitch/roll.
    private func recenterLocked(on m: MotionPacket) {
        let q = Self.worldOrientation(m.attitude)
        let normal = q.act(SIMD3<Float>(0, 0, 1))   // out of the screen
        let top = q.act(SIMD3<Float>(0, 1, 0))      // toward the top of the phone
        let yaw: Float
        if simd_length(SIMD2(normal.x, normal.z)) > 0.35 {
            yaw = atan2(normal.x, normal.z)          // standing up: point the screen at +Z (camera)
        } else {
            yaw = atan2(-top.x, -top.z)              // lying flat: point the top away from the camera
        }
        recenterOffset = simd_quatf(angle: -yaw, axis: SIMD3(0, 1, 0))
    }

    static func worldOrientation(_ attitude: simd_quatf) -> simd_quatf { coreMotionToWorld * attitude }
}
