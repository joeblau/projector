import Foundation
import simd

/// Binary wire protocol between the iPhone and the Mac. Little-endian, fixed layout.
enum Wire {
    static let magic: UInt16 = 0x5050          // "PP"
    static let version: UInt8 = 1
    static let serviceType = "_phoneproj._udp"
    static let port: UInt16 = 47800
    static let videoServiceType = "_phoneprojv._tcp"
    /// TCP, same number as the UDP telemetry port so resolving the Bonjour service gives the right port for both.
    static let videoPort: UInt16 = 47800
}

/// TCP video channel framing: [u32 length of (type + payload)] [u8 type] [payload]
enum VideoMessageType: UInt8 {
    case format = 1   // u16 width, u16 height, u8 count, (u16 len + bytes) HEVC parameter sets (VPS/SPS/PPS)
    case frame = 2    // u8 flags (bit0 = keyframe), f64 sentAt, AVCC-framed HEVC NAL units
}

enum TelemetrySource: UInt8, Sendable {
    case app = 1        // foreground companion app
    case broadcast = 2  // ReplayKit broadcast extension (runs over any app)

    var label: String { self == .app ? "App" : "Broadcast" }
}

enum PacketType: UInt8 { case motion = 1, status = 2, log = 3 }

/// 100 Hz fused device-motion sample. 92 bytes on the wire.
struct MotionPacket: Sendable {
    var source: TelemetrySource
    var seq: UInt32
    var timestamp: Double            // CMLogItem timestamp (s since boot)
    var sentAt: Double               // wall clock (s since 1970)
    var attitude: simd_quatf         // device -> reference frame (CoreMotion, Z-up)
    var rotationRate: SIMD3<Float>   // rad/s, device frame
    var userAcceleration: SIMD3<Float> // g, device frame, gravity removed
    var gravity: SIMD3<Float>        // g, device frame
    var magneticField: SIMD3<Float>  // µT, device frame (0 when uncalibrated)
    var heading: Float               // degrees, -1 when unavailable
}

/// 1 Hz device status.
struct StatusPacket: Sendable {
    var source: TelemetrySource
    var batteryLevel: Float          // 0...1, -1 unknown
    var batteryState: UInt8          // UIDevice.BatteryState raw
    var thermalState: UInt8          // ProcessInfo.ThermalState raw
    var videoFrameHz: UInt16         // ReplayKit frames/s (broadcast only)
    var uptime: Float                // seconds since streamer started
    var memoryMB: Float              // phys_footprint of the sending process
    var modelIdentifier: String      // e.g. "iPhone18,4"
    var deviceName: String           // up to 64 bytes UTF-8
}

// MARK: - Encoding

struct ByteWriter {
    private(set) var data = Data()
    init(capacity: Int) { data.reserveCapacity(capacity) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    mutating func v3(_ v: SIMD3<Float>) { f32(v.x); f32(v.y); f32(v.z) }
    mutating func header(_ type: PacketType, _ source: TelemetrySource) {
        u16(Wire.magic); u8(Wire.version); u8(type.rawValue); u8(source.rawValue)
    }
}

struct ByteReader {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    mutating func take<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size
        return T(littleEndian: v)
    }
    mutating func u8() -> UInt8? { take(UInt8.self) }
    mutating func u16() -> UInt16? { take(UInt16.self) }
    mutating func u32() -> UInt32? { take(UInt32.self) }
    mutating func f32() -> Float? { u32().map(Float.init(bitPattern:)) }
    mutating func f64() -> Double? { take(UInt64.self).map(Double.init(bitPattern:)) }
    mutating func v3() -> SIMD3<Float>? {
        guard let x = f32(), let y = f32(), let z = f32() else { return nil }
        return SIMD3(x, y, z)
    }
    mutating func bytes(_ n: Int) -> Data? {
        guard offset + n <= data.count else { return nil }
        defer { offset += n }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
    }
}

extension MotionPacket {
    func encoded() -> Data {
        var w = ByteWriter(capacity: 96)
        w.header(.motion, source)
        w.u32(seq); w.f64(timestamp); w.f64(sentAt)
        w.f32(attitude.vector.x); w.f32(attitude.vector.y); w.f32(attitude.vector.z); w.f32(attitude.vector.w)
        w.v3(rotationRate); w.v3(userAcceleration); w.v3(gravity); w.v3(magneticField)
        w.f32(heading)
        return w.data
    }
}

extension StatusPacket {
    func encoded() -> Data {
        var w = ByteWriter(capacity: 96)
        w.header(.status, source)
        w.f32(batteryLevel); w.u8(batteryState); w.u8(thermalState); w.u16(videoFrameHz); w.f32(uptime); w.f32(memoryMB)
        var d = w.data
        for str in [modelIdentifier, deviceName] {
            let bytes = Data(str.utf8.prefix(64))
            d.append(UInt8(bytes.count)); d.append(bytes)
        }
        return d
    }
}

enum DecodedPacket {
    case motion(MotionPacket)
    case status(StatusPacket)
    case log(TelemetrySource, String)
}

/// Debug line from the phone (the broadcast extension has no console we can read from the Mac).
func encodeLog(_ message: String, source: TelemetrySource) -> Data {
    var w = ByteWriter(capacity: 64)
    w.header(.log, source)
    var d = w.data
    d.append(Data(message.utf8.prefix(1000)))
    return d
}

enum WireDecoder {
    static func decode(_ data: Data) -> DecodedPacket? {
        var r = ByteReader(data)
        guard r.u16() == Wire.magic, r.u8() == Wire.version,
              let typeRaw = r.u8(), let type = PacketType(rawValue: typeRaw),
              let srcRaw = r.u8(), let source = TelemetrySource(rawValue: srcRaw) else { return nil }
        switch type {
        case .motion:
            guard let seq = r.u32(), let ts = r.f64(), let sent = r.f64(),
                  let qx = r.f32(), let qy = r.f32(), let qz = r.f32(), let qw = r.f32(),
                  let rot = r.v3(), let acc = r.v3(), let grav = r.v3(), let mag = r.v3(),
                  let heading = r.f32() else { return nil }
            return .motion(MotionPacket(source: source, seq: seq, timestamp: ts, sentAt: sent,
                                        attitude: simd_quatf(ix: qx, iy: qy, iz: qz, r: qw),
                                        rotationRate: rot, userAcceleration: acc, gravity: grav,
                                        magneticField: mag, heading: heading))
        case .log:
            return .log(source, String(decoding: data.dropFirst(5), as: UTF8.self))
        case .status:
            guard let bl = r.f32(), let bs = r.u8(), let th = r.u8(), let fhz = r.u16(), let up = r.f32(), let mem = r.f32(),
                  let mn = r.u8(), let modelData = r.bytes(Int(mn)),
                  let n = r.u8(), let nameData = r.bytes(Int(n)) else { return nil }
            return .status(StatusPacket(source: source, batteryLevel: bl, batteryState: bs, thermalState: th,
                                        videoFrameHz: fhz, uptime: up, memoryMB: mem,
                                        modelIdentifier: String(decoding: modelData, as: UTF8.self),
                                        deviceName: String(decoding: nameData, as: UTF8.self)))
        }
    }
}
