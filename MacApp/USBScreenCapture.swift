import AVFoundation
import CoreMediaIO
import Foundation

/// The QuickTime path: a cabled iPhone/iPad exposes its screen as a muxed AVCaptureDevice once
/// CoreMediaIO screen-capture devices are allowed. No broadcast needed; lowest latency.
final class USBScreenCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let store: VideoFrameStore
    private let preferredName: () -> String?
    private let queue = DispatchQueue(label: "projector.usb", qos: .userInteractive)
    private var session: AVCaptureSession?
    private var deviceID: String?
    private var timer: DispatchSourceTimer?

    init(store: VideoFrameStore, preferredName: @escaping () -> String?) {
        self.store = store
        self.preferredName = preferredName
    }

    func start() {
        Self.allowScreenCaptureDevices()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if !granted { NSLog("[usb] camera permission denied; USB mirroring disabled") }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let dev = note.object as? AVCaptureDevice else { return }
            self.queue.async { if dev.uniqueID == self.deviceID { self.stopSession() } }
        }
        // iOS devices show up a moment after the property is set; poll for (re)connection.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 2)
        t.setEventHandler { [weak self] in self?.connectIfNeeded() }
        t.resume()
        timer = t
    }

    private static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private func connectIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
            .devices.filter { $0.modelID == "iOS Device" || $0.manufacturer == "Apple Inc." }
        let want = preferredName()
        // Prefer the device that's sending telemetry; otherwise any cabled iOS device.
        let pick = devices.first { $0.localizedName == want } ?? devices.first
        guard let pick else { return }
        if pick.uniqueID == deviceID, session?.isRunning == true { return }
        startSession(with: pick)
    }

    private func startSession(with device: AVCaptureDevice) {
        stopSession()
        let s = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else { return }
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                             kCVPixelBufferMetalCompatibilityKey as String: true]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(out) else { return }
        s.addOutput(out)
        s.startRunning()
        session = s
        deviceID = device.uniqueID
        store.setUSBDevice(device.localizedName)
        NSLog("[usb] mirroring \(device.localizedName)")
    }

    private func stopSession() {
        session?.stopRunning()
        session = nil
        deviceID = nil
        store.setUSBDevice(nil)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        store.publish(pb, source: .usb, latencyMs: nil)
    }
}
