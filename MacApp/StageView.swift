import CoreVideo
import RealityKit
import SwiftUI

/// Fullscreen 3D stage: the phone follows the real device's orientation and shows its live screen.
struct StageView: View {
    let hub: TelemetryHub
    let video: VideoFrameStore
    let controls: StageControls
    @State private var subscription: EventSubscription?

    var body: some View {
        RealityView { content in
            let pivot = Entity()
            content.add(pivot)

            var currentModel: String? = "__initial__"
            var loadingModel: String?
            let initial = await DeviceModels.body(for: nil)
            var phone = initial.root
            var screen = initial.screen
            pivot.addChild(phone)

            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = StageControls.fovDegrees
            camera.camera.near = 0.01
            camera.look(at: .zero, from: [0, 0.02, StageControls.defaultDistance], relativeTo: nil)
            content.add(camera)
            var camDistance = StageControls.defaultDistance
            var camTarget = SIMD2<Float>.zero

            let key = DirectionalLight()
            key.light.intensity = 3500
            key.look(at: .zero, from: [0.4, 0.6, 0.5], relativeTo: nil)
            content.add(key)
            let rim = DirectionalLight()
            rim.light.intensity = 1800
            rim.light.color = NSColor(calibratedRed: 0.6, green: 0.7, blue: 1, alpha: 1)
            rim.look(at: .zero, from: [-0.5, 0.2, -0.6], relativeTo: nil)
            content.add(rim)

            let videoTexture = VideoTexture()
            var videoGeneration = 0
            // Portrait footprint of the current screen plane; landscape frames (USB capture after an app
            // rotates) are drawn on a swapped plane turned ±90° so they stay upright on the glass.
            var portraitSize = screen.model?.mesh.bounds.extents ?? .zero
            var screenRotation = 0   // 0, +1 (+90°), -1 (-90°)
            func layoutScreen(for pb: CVPixelBuffer) {
                let landscape = CVPixelBufferGetWidth(pb) > CVPixelBufferGetHeight(pb)
                var wanted = 0
                if landscape {
                    // Keep the current direction while landscape; pick it from gravity on entry.
                    // Top of phone pointing left => device +X is down => gravity.x > 0 => content top is -X => +90°.
                    wanted = screenRotation != 0 ? screenRotation : ((hub.gravity()?.x ?? 1) >= 0 ? 1 : -1)
                }
                guard wanted != screenRotation else { return }
                screenRotation = wanted
                let (w, h) = (portraitSize.x, portraitSize.y)
                let mesh: MeshResource = wanted == 0
                    ? .generatePlane(width: w, height: h, cornerRadius: min(w, h) * 0.12)
                    : .generatePlane(width: h, height: w, cornerRadius: min(w, h) * 0.12)
                screen.model?.mesh = mesh
                screen.orientation = simd_quatf(angle: Float(wanted) * .pi / 2, axis: [0, 0, 1])
            }
            var showingVideo = false
            var smoothedOffset = SIMD3<Float>.zero

            let sub = content.subscribe(to: SceneEvents.Update.self) { event in
                let dt = Float(event.deltaTime)

                // Camera framing eases toward the zoom/pan the user asked for.
                let k = 1 - exp(-dt / 0.06)
                camDistance += (controls.distance - camDistance) * k
                camTarget += (controls.target - camTarget) * k
                let look = SIMD3(camTarget.x, camTarget.y, 0)
                camera.look(at: look, from: look + SIMD3(0, 0.02 * camDistance / StageControls.defaultDistance, camDistance),
                            relativeTo: nil)

                // Swap the body (Apple's model when available) when a different device connects.
                let wantedModel = hub.modelIdentifier()
                if wantedModel != nil, wantedModel != currentModel, wantedModel != loadingModel {
                    loadingModel = wantedModel
                    Task { @MainActor in
                        let body = await DeviceModels.body(for: wantedModel)
                        guard loadingModel == wantedModel else { return }
                        body.root.orientation = phone.orientation
                        phone.removeFromParent()
                        phone = body.root
                        screen = body.screen
                        portraitSize = screen.model?.mesh.bounds.extents ?? .zero
                        screenRotation = 0
                        pivot.addChild(phone)
                        if showingVideo, let r = videoTexture.resource { screen.model?.materials = [PhoneEntity.videoMaterial(r)] }
                        currentModel = wantedModel
                        loadingModel = nil
                        hub.setBodyName(body.displayName)
                    }
                }

                // Live screen.
                if let (pb, gen) = video.frame(newerThan: videoGeneration) {
                    videoGeneration = gen
                    if let pb {
                        layoutScreen(for: pb)
                        if let newResource = videoTexture.update(with: pb) {
                            screen.model?.materials = [PhoneEntity.videoMaterial(newResource)]
                        } else if !showingVideo, let r = videoTexture.resource {
                            screen.model?.materials = [PhoneEntity.videoMaterial(r)]
                        }
                        showingVideo = true
                    } else if showingVideo {
                        screen.model?.materials = [PhoneEntity.placeholderScreen()]
                        showingVideo = false
                    }
                }

                // Orientation.
                if let target = hub.targetOrientation() {
                    // Filtering happens at 100 Hz in the hub; this only bridges the gaps between samples.
                    let a = 1 - exp(-dt / 0.012)
                    phone.orientation = simd_slerp(phone.orientation, target, a)
                } else {
                    let spin = simd_quatf(angle: dt * 0.4, axis: [0, 1, 0])
                    phone.orientation = simd_normalize(spin * phone.orientation)
                }

                let accel = hub.worldUserAcceleration()
                let targetOffset = simd_clamp(accel * -0.025, SIMD3(repeating: -0.03), SIMD3(repeating: 0.03))
                smoothedOffset += (targetOffset - smoothedOffset) * (1 - exp(-dt / 0.08))
                pivot.position = smoothedOffset
            }
            Task { @MainActor in subscription = sub }
        }
        .realityViewCameraControls(.none)
    }
}
