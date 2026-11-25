import AppKit
import Observation
import simd

/// View state shared by the 3D stage, HUD, menus and input monitors.
@MainActor @Observable
final class StageControls {
    static let defaultDistance: Float = 0.36
    static let fovDegrees: Float = 32
    static let distanceRange: ClosedRange<Float> = 0.10...1.4

    /// Desired camera framing; the renderer eases toward it.
    var distance: Float = defaultDistance
    var target = SIMD2<Float>(0, 0)          // pan offset on the z = 0 plane (meters)
    var pureScreen = false                   // video only, fills the display
    var showHUD = true
    var viewportAspect: Float = 16.0 / 9.0

    private var halfHeight: Float { distance * tan(Self.fovDegrees * .pi / 360) }

    /// Zoom by `factor` (<1 zooms in) keeping the world point under `cursor` (NDC -1...1, y up) fixed.
    func zoom(by factor: Float, at cursor: SIMD2<Float>) {
        let oldHalf = SIMD2(halfHeight * viewportAspect, halfHeight)
        let world = target + cursor * oldHalf
        distance = min(max(distance * factor, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        let newHalf = SIMD2(halfHeight * viewportAspect, halfHeight)
        target = world - cursor * newHalf
        clampTarget()
    }

    /// Pan by a drag delta in points within a viewport of `size` points.
    func pan(by delta: CGSize, in size: CGSize) {
        guard size.height > 0 else { return }
        let metersPerPoint = 2 * halfHeight / Float(size.height)
        target -= SIMD2(Float(delta.width), -Float(delta.height)) * metersPerPoint
        clampTarget()
    }

    func step(zoomIn: Bool) { zoom(by: zoomIn ? 0.8 : 1.25, at: .zero) }

    func resetView() { distance = Self.defaultDistance; target = .zero }

    private func clampTarget() { target = simd_clamp(target, SIMD2(repeating: -0.25), SIMD2(repeating: 0.25)) }
}
