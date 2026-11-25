import CoreMedia
import CoreVideo
import Foundation
import Network
import QuartzCore
import VideoToolbox

/// Latest frame from each video source + stats, shared between capture/decoder threads and the renderer.
/// USB capture wins when present (lowest latency); the broadcast's network stream is the fallback.
final class VideoFrameStore: @unchecked Sendable {
    enum Source: String { case usb = "USB", network = "Broadcast" }
    struct Stats {
        var connected = false; var source: Source?; var width = 0; var height = 0
        var fps = 0; var kbps = 0; var latencyMs: Double?; var usbDevice: String?
    }

    private struct Slot { var buffer: CVPixelBuffer?; var at: CFTimeInterval = 0; var times: [CFTimeInterval] = [] }
    private let lock = NSLock()
    private var slots: [Source: Slot] = [:]
    private var generation = 0
    private var byteLog: [(CFTimeInterval, Int)] = []
    private var networkConnected = false
    private var usbDevice: String?
    private var latencyMs: Double?

    func publish(_ pb: CVPixelBuffer, source: Source = .network, latencyMs: Double?) {
        let now = CACurrentMediaTime()
        lock.withLock {
            var slot = slots[source] ?? Slot()
            slot.buffer = pb; slot.at = now
            slot.times.append(now); slot.times.removeAll { now - $0 > 1 }
            slots[source] = slot
            generation += 1
            if source == .network, let latencyMs { self.latencyMs = latencyMs }
        }
    }
    func countBytes(_ n: Int) {
        let now = CACurrentMediaTime()
        lock.withLock { byteLog.append((now, n)); byteLog.removeAll { now - $0.0 > 1 } }
    }
    func setConnected(_ c: Bool) {
        lock.withLock {
            networkConnected = c
            if !c { slots[.network] = nil; generation += 1; byteLog = [] }
        }
    }
    func setUSBDevice(_ name: String?) {
        lock.withLock {
            usbDevice = name
            if name == nil { slots[.usb] = nil; generation += 1 }
        }
    }

    private func activeLocked(now: CFTimeInterval) -> Source? {
        for s in [Source.usb, .network] { if let slot = slots[s], slot.buffer != nil, now - slot.at < 1.5 { return s } }
        // Screens only send frames on change: keep showing the last frame while the source is still connected.
        if usbDevice != nil, slots[.usb]?.buffer != nil { return .usb }
        if networkConnected, slots[.network]?.buffer != nil { return .network }
        return nil
    }

    /// Returns the preferred source's frame if anything changed since `since` (nil buffer = no video).
    func frame(newerThan since: Int) -> (CVPixelBuffer?, Int)? {
        lock.withLock {
            guard generation != since else { return nil }
            let src = activeLocked(now: CACurrentMediaTime())
            return (src.flatMap { slots[$0]?.buffer }, generation)
        }
    }

    func snapshot() -> Stats {
        let now = CACurrentMediaTime()
        return lock.withLock {
            var s = Stats()
            s.usbDevice = usbDevice
            s.connected = networkConnected || usbDevice != nil
            if let src = activeLocked(now: now), let slot = slots[src], let pb = slot.buffer {
                s.source = src
                s.width = CVPixelBufferGetWidth(pb); s.height = CVPixelBufferGetHeight(pb)
                s.fps = slot.times.filter { now - $0 <= 1 }.count
                if src == .network {
                    s.kbps = byteLog.filter { now - $0.0 <= 1 }.reduce(0) { $0 + $1.1 } * 8 / 1000
                    s.latencyMs = latencyMs
                }
            }
            return s
        }
    }
}

/// TCP listener (Bonjour `_phoneprojv._tcp`) + HEVC hardware decoder.
final class VideoReceiver: @unchecked Sendable {
    private let store: VideoFrameStore
    private let queue = DispatchQueue(label: "projector.video", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var formatDesc: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?

    init(store: VideoFrameStore) { self.store = store }

    func start() {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do { l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Wire.videoPort)!) }
        catch { NSLog("[video] listener init failed: \(error)"); return }
        // No Bonjour advert here: the phone reuses the address it resolved for the telemetry service.
        l.stateUpdateHandler = { NSLog("[video] listener state: \($0)") }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ c: NWConnection) {
        // One phone at a time; the newest connection wins.
        connection?.cancel()
        connection = c
        resetDecoder()
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, c === self.connection else { return }
            switch s {
            case .ready:
                NSLog("[video] phone connected from \(c.endpoint)")
                self.store.setConnected(true)
            case .failed, .cancelled: self.store.setConnected(false); self.connection = nil
            default: break
            }
        }
        c.start(queue: queue)
        readHeader(c)
    }

    private func readHeader(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, done, err in
            guard let self, let data, data.count == 5, err == nil else { if done || err != nil { c.cancel() }; return }
            var r = ByteReader(data)
            let len = Int(r.u32()!), type = r.u8()!
            let bodyLen = len - 1
            guard bodyLen >= 0, bodyLen < 16_000_000 else { NSLog("[video] bad header len=\(len) type=\(type); dropping connection"); c.cancel(); return }
            if bodyLen == 0 { self.readHeader(c); return }
            c.receive(minimumIncompleteLength: bodyLen, maximumLength: bodyLen) { body, _, _, err in
                guard let body, body.count == bodyLen, err == nil else { c.cancel(); return }
                self.store.countBytes(bodyLen + 5)
                self.handle(type: type, body: body)
                self.readHeader(c)
            }
        }
    }

    private func handle(type: UInt8, body: Data) {
        switch VideoMessageType(rawValue: type) {
        case .format: handleFormat(body)
        case .frame: handleFrame(body)
        case nil: break
        }
    }

    private func handleFormat(_ body: Data) {
        var r = ByteReader(body)
        guard r.u16() != nil, r.u16() != nil, let codec = r.u8(), let n = r.u8() else { return }
        var sets: [Data] = []
        for _ in 0..<n { guard let l = r.u16(), let d = r.bytes(Int(l)) else { return }; sets.append(d) }
        var desc: CMVideoFormatDescription?
        let status: OSStatus = withPointers(sets) { ptrs, sizes in
            codec == 2
                ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                      parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                      nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                      parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                      nalUnitHeaderLength: 4, extensions: nil,
                                                                      formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { NSLog("[video] bad format (codec \(codec)): \(status)"); return }
        NSLog("[video] format \(codec == 2 ? "H.264" : "HEVC") \(CMVideoFormatDescriptionGetDimensions(desc))")
        if let old = formatDesc, CMFormatDescriptionEqual(old, otherFormatDescription: desc) { return }
        resetDecoder()
        formatDesc = desc
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var session: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                     imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                     decompressionSessionOut: &session)
        if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        decoder = session
    }

    private func handleFrame(_ body: Data) {
        guard let decoder, let formatDesc, body.count > 9 else { return }
        let sentAt = body.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt64.self))) }
        let nalLen = body.count - 9

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: nalLen, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: nalLen, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        body.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + 9, blockBuffer: block, offsetIntoDestination: 0, dataLength: nalLen)
        }
        var sample: CMSampleBuffer?
        var size = nalLen
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: formatDesc, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        let store = self.store
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { NSLog("[video] decode error \(status)"); return }
            let ms = (Date().timeIntervalSince1970 - sentAt) * 1000
            store.publish(image, latencyMs: (ms > -50 && ms < 3000) ? max(ms, 0) : nil)
        }
    }

    private func resetDecoder() {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil; formatDesc = nil
    }
}

private func withPointers<R>(_ sets: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
    // Copy into stable buffers for the duration of the call.
    let buffers = sets.map { d -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(d.count, 1))
        d.copyBytes(to: p, count: d.count); return p
    }
    defer { buffers.forEach { $0.deallocate() } }
    return body(buffers.map { UnsafePointer($0) }, sets.map(\.count))
}
