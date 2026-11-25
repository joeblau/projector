import CoreMotion
import simd
import Foundation
import UIKit

/// Samples CoreMotion at 100 Hz and streams it to the Mac. Used by the app and the broadcast extension.
final class TelemetryStreamer: @unchecked Sendable {
    let source: TelemetrySource
    let link = MacLink()
    var onSample: ((MotionPacket) -> Void)?

    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .userInteractive; return q
    }()
    private var statusTimer: DispatchSourceTimer?
    private var seq: UInt32 = 0
    private var startedAt = Date()
    private let frameLock = NSLock()
    private var framesThisSecond = 0
    private let deviceName: String

    init(source: TelemetrySource) {
        self.source = source
        link.source = source
        deviceName = UIDevice.current.name
    }

    func start(rateHz: Double = 100) {
        startedAt = Date()
        link.start()
        UIDevice.current.isBatteryMonitoringEnabled = true

        motion.deviceMotionUpdateInterval = 1.0 / rateHz
        let frame: CMAttitudeReferenceFrame = .xArbitraryCorrectedZVertical
        motion.startDeviceMotionUpdates(using: frame, to: motionQueue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.seq &+= 1
            let q = dm.attitude.quaternion
            let field = dm.magneticField
            let packet = MotionPacket(
                source: self.source, seq: self.seq, timestamp: dm.timestamp,
                sentAt: Date().timeIntervalSince1970,
                attitude: simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w)),
                rotationRate: SIMD3(Float(dm.rotationRate.x), Float(dm.rotationRate.y), Float(dm.rotationRate.z)),
                userAcceleration: SIMD3(Float(dm.userAcceleration.x), Float(dm.userAcceleration.y), Float(dm.userAcceleration.z)),
                gravity: SIMD3(Float(dm.gravity.x), Float(dm.gravity.y), Float(dm.gravity.z)),
                magneticField: field.accuracy == .uncalibrated ? .zero
                    : SIMD3(Float(field.field.x), Float(field.field.y), Float(field.field.z)),
                heading: dm.heading >= 0 ? Float(dm.heading) : -1)
            self.link.send(packet.encoded())
            self.onSample?(packet)
        }

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "projector.status"))
        t.schedule(deadline: .now() + 0.5, repeating: 1)
        t.setEventHandler { [weak self] in self?.sendStatus() }
        t.resume()
        statusTimer = t
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        statusTimer?.cancel(); statusTimer = nil
        link.stop()
    }

    /// Called by the broadcast extension for every ReplayKit video frame.
    func countVideoFrame() {
        frameLock.lock(); framesThisSecond += 1; frameLock.unlock()
    }

    private func sendStatus() {
        frameLock.lock(); let frames = framesThisSecond; framesThisSecond = 0; frameLock.unlock()
        let device = UIDevice.current
        let status = StatusPacket(
            source: source,
            batteryLevel: device.batteryLevel,
            batteryState: UInt8(device.batteryState.rawValue),
            thermalState: UInt8(ProcessInfo.processInfo.thermalState.rawValue),
            videoFrameHz: UInt16(min(frames, Int(UInt16.max))),
            uptime: Float(Date().timeIntervalSince(startedAt)),
            memoryMB: DeviceInfo.memoryFootprintMB(),
            modelIdentifier: DeviceInfo.modelIdentifier,
            deviceName: deviceName)
        link.send(status.encoded())
    }
}
