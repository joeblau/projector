import CoreMedia
import Foundation
import VideoToolbox

/// Hardware video encoder tuned for low latency (HEVC, falling back to H.264). Emits format + frame
/// messages to the VideoLink and keeps counters so the Mac can see what the extension is doing.
final class VideoEncoder: @unchecked Sendable {
    enum Codec: UInt8 { case hevc = 1, h264 = 2 }

    struct Counters {
        var encodeCalls = 0, notReady = 0, outputs = 0, sent = 0, keyframes = 0
        var droppedBackpressure = 0, droppedWaitingKey = 0
        var encodeErrors = 0, lastError: OSStatus = 0, sessionsCreated = 0
    }

    private let link: VideoLink
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private(set) var codec: Codec = .hevc
    private let lock = NSLock()
    private var needsKeyframe = true
    private var lastFormat = Data()
    private var consecutiveErrors = 0
    private var counters = Counters()
    /// Drop frames when more than this is queued on the socket (~0.5 s at 12 Mbps).
    private let maxInflight = 750_000

    init(link: VideoLink) {
        self.link = link
        link.onReady = { [weak self] in self?.requestKeyframe() }
    }

    func requestKeyframe() { lock.withLock { needsKeyframe = true; lastFormat = Data() } }

    func countersSnapshot() -> Counters { lock.withLock { counters } }

    /// Call on the encode queue only.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock { counters.encodeCalls += 1 }
        guard link.isReady else { lock.withLock { counters.notReady += 1 }; return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer)), h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || w != width || h != height { makeSession(width: w, height: h) }
        guard let session else { return }

        let forceKey = lock.withLock { needsKeyframe }
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sbuf in
            guard let self else { return }
            guard status == noErr, let sbuf else { self.recordError(status); return }
            self.lock.withLock { self.consecutiveErrors = 0 }
            self.handleEncoded(sbuf)
        }
        if status != noErr { recordError(status) }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func recordError(_ status: OSStatus) {
        let (rebuild, fallback): (Bool, Bool) = lock.withLock {
            counters.encodeErrors += 1
            counters.lastError = status
            consecutiveErrors += 1
            // -12903 kVTInvalidSessionErr: the hardware session was torn down (e.g. resource reclaim). Rebuild.
            let rebuild = status == kVTInvalidSessionErr || consecutiveErrors >= 5
            let fallback = codec == .hevc && consecutiveErrors >= 15
            return (rebuild, fallback)
        }
        if fallback { codec = .h264 }
        if rebuild { width = 0; height = 0 }   // forces makeSession on the next frame (encode queue)
    }

    private func makeSession(width w: Int32, height h: Int32) {
        invalidate()
        width = w; height = h
        var s: VTCompressionSession?
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let spec: CFDictionary? = codec == .h264
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
            : nil
        let st = VTCompressionSessionCreate(allocator: nil, width: w, height: h, codecType: type,
                                            encoderSpecification: spec, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                            compressionSessionOut: &s)
        guard st == noErr, let s else { recordError(st); return }
        let set = { (k: CFString, v: CFTypeRef) in VTSessionSetProperty(s, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, 10_000_000 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        lock.withLock { counters.sessionsCreated += 1 }
        requestKeyframe()
    }

    private func handleEncoded(_ sbuf: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let inflight = link.inflightBytes

        // Backpressure: if the socket is behind, drop until the next keyframe rather than adding latency.
        let drop: Bool = lock.withLock {
            counters.outputs += 1
            if inflight > maxInflight { needsKeyframe = true; counters.droppedBackpressure += 1; return true }
            if needsKeyframe && !isKey { counters.droppedWaitingKey += 1; return true }
            if isKey { needsKeyframe = false; counters.keyframes += 1 }
            return false
        }
        if drop { return }

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sbuf) {
            let payload = formatPayload(fmt)
            let changed = lock.withLock { () -> Bool in
                defer { lastFormat = payload }
                return payload != lastFormat
            }
            if changed { link.send(type: .format, payload: payload) }
        }

        guard let block = CMSampleBufferGetDataBuffer(sbuf) else { return }
        let len = CMBlockBufferGetDataLength(block)
        var payload = Data(count: 9 + len)
        payload.withUnsafeMutableBytes { raw in
            raw[0] = isKey ? 1 : 0
            raw.storeBytes(of: Date().timeIntervalSince1970.bitPattern.littleEndian, toByteOffset: 1, as: UInt64.self)
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: raw.baseAddress! + 9)
        }
        link.send(type: .frame, payload: payload)
        lock.withLock { counters.sent += 1 }
    }

    /// u16 width, u16 height, u8 codec, u8 count, (u16 len + bytes) parameter sets.
    private func formatPayload(_ fmt: CMFormatDescription) -> Data {
        var w = ByteWriter(capacity: 128)
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        w.u16(UInt16(dims.width)); w.u16(UInt16(dims.height))
        let isHEVC = CMFormatDescriptionGetMediaSubType(fmt) == kCMVideoCodecType_HEVC
        w.u8(isHEVC ? Codec.hevc.rawValue : Codec.h264.rawValue)
        func get(_ i: Int, _ ptr: UnsafeMutablePointer<UnsafePointer<UInt8>?>?, _ size: UnsafeMutablePointer<Int>?,
                 _ count: UnsafeMutablePointer<Int>?) -> OSStatus {
            isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: ptr,
                                                                     parameterSetSizeOut: size, parameterSetCountOut: count,
                                                                     nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: ptr,
                                                                     parameterSetSizeOut: size, parameterSetCountOut: count,
                                                                     nalUnitHeaderLengthOut: nil)
        }
        var count = 0
        _ = get(0, nil, nil, &count)
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?; var size = 0
            if get(i, &ptr, &size, nil) == noErr, let ptr { sets.append(Data(bytes: ptr, count: size)) }
        }
        w.u8(UInt8(sets.count))
        var d = w.data
        for s in sets {
            withUnsafeBytes(of: UInt16(s.count).littleEndian) { d.append(contentsOf: $0) }
            d.append(s)
        }
        return d
    }
}
