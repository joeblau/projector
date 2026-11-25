import Foundation
import simd

/// How much to smooth hand-held motion. Applied at the 100 Hz sample rate, before rendering.
enum SmoothingLevel: Int, CaseIterable {
    case off, light, medium, heavy

    var label: String { ["Off", "Light", "Medium", "Heavy"][rawValue] }
    /// One Euro parameters: cutoff (Hz) while still, and how fast it opens up per rad/s of rotation.
    var minCutoff: Float { [0, 2.5, 1.2, 0.6][rawValue] }
    var beta: Float { [0, 0.8, 0.5, 0.3][rawValue] }

    var next: SmoothingLevel { SmoothingLevel(rawValue: (rawValue + 1) % Self.allCases.count)! }
}

/// One Euro filter for orientation (Casiez et al. 2012), using the gyro for the speed term:
/// heavy smoothing when the phone is nearly still (kills tremor/sensor noise), almost none when it moves fast
/// (no lag on real motion).
struct OneEuroQuaternion {
    private var value: simd_quatf?
    private var speed: Float = 0
    private var lastTime: Double = 0
    /// How quickly the speed estimate reacts; high so motion onset opens the filter immediately.
    private let speedCutoff: Float = 4

    mutating func reset() { value = nil; speed = 0 }

    mutating func filter(_ x: simd_quatf, time t: Double, angularSpeed: Float, level: SmoothingLevel) -> simd_quatf {
        guard level != .off, let prev = value, t > lastTime, t - lastTime < 0.25 else {
            value = x; lastTime = t; return x
        }
        let dt = Float(t - lastTime)
        lastTime = t
        speed += (angularSpeed - speed) * Self.alpha(dt: dt, cutoff: speedCutoff)
        let cutoff = level.minCutoff + level.beta * speed
        let target = simd_dot(prev.vector, x.vector) < 0 ? simd_quatf(vector: -x.vector) : x   // shortest path
        let out = simd_normalize(simd_slerp(prev, target, Self.alpha(dt: dt, cutoff: cutoff)))
        value = out
        return out
    }

    static func alpha(dt: Float, cutoff: Float) -> Float {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Low-pass + small dead zone for the linear-acceleration "jolt" so resting noise doesn't wiggle the model.
struct JoltFilter {
    private var value = SIMD3<Float>.zero
    private var lastTime: Double = 0

    mutating func reset() { value = .zero }

    mutating func filter(_ a: SIMD3<Float>, time t: Double, level: SmoothingLevel) -> SIMD3<Float> {
        defer { lastTime = t }
        guard level != .off, t > lastTime, t - lastTime < 0.25 else { value = a; return a }
        let deadZone: Float = 0.02 * Float(level.rawValue)            // g
        let mag = simd_length(a)
        let gated = mag > deadZone ? a * ((mag - deadZone) / mag) : .zero
        value += (gated - value) * OneEuroQuaternion.alpha(dt: Float(t - lastTime), cutoff: 6 / Float(level.rawValue))
        return value
    }
}
