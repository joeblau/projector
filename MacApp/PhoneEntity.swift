import AppKit
import RealityKit

/// Physical dimensions per model. Local axes match CoreMotion's device frame:
/// +X right, +Y toward the top, +Z out of the screen.
struct PhoneSpec: Equatable {
    enum Camera { case proPlateau, airBar }
    var name: String
    var width: Float, height: Float, depth: Float, corner: Float
    var bezel: Float
    var camera: Camera
    var frameColor: NSColor

    static let iPhone17Pro = PhoneSpec(name: "iPhone 17 Pro", width: 0.0716, height: 0.1497, depth: 0.0083, corner: 0.0095,
                                       bezel: 0.0023, camera: .proPlateau,
                                       frameColor: NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.48, alpha: 1))
    static let iPhoneAir = PhoneSpec(name: "iPhone Air", width: 0.0747, height: 0.1562, depth: 0.00564, corner: 0.0105,
                                     bezel: 0.0021, camera: .airBar,
                                     frameColor: NSColor(calibratedRed: 0.80, green: 0.79, blue: 0.76, alpha: 1))

    static func forModel(_ id: String?) -> PhoneSpec {
        switch id {
        case "iPhone18,4": return .iPhoneAir
        default: return .iPhone17Pro
        }
    }
}

enum PhoneEntity {
    @MainActor
    static func make(_ spec: PhoneSpec) -> (root: Entity, screen: ModelEntity) {
        let (w, h, d) = (spec.width, spec.height, spec.depth)
        let root = Entity()
        root.name = "phone"

        var frame = PhysicallyBasedMaterial()
        frame.baseColor = .init(tint: spec.frameColor)
        frame.metallic = 1.0
        frame.roughness = 0.3
        root.addChild(ModelEntity(mesh: .generateBox(width: w, height: h, depth: d, cornerRadius: spec.corner), materials: [frame]))

        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: .black)
        glass.roughness = 0.05
        glass.clearcoat = 1.0
        let bezel = ModelEntity(mesh: .generatePlane(width: w - 0.0012, height: h - 0.0012, cornerRadius: spec.corner - 0.0006),
                                materials: [glass])
        bezel.position.z = d / 2 + 0.0001
        root.addChild(bezel)

        let inset = spec.bezel * 2
        let screen = ModelEntity(mesh: .generatePlane(width: w - inset, height: h - inset, cornerRadius: spec.corner - spec.bezel),
                                 materials: [placeholderScreen()])
        screen.name = "screen"
        screen.position.z = d / 2 + 0.0002
        root.addChild(screen)

        let island = ModelEntity(mesh: .generateBox(width: 0.019, height: 0.0055, depth: 0.0002, cornerRadius: 0.0027),
                                 materials: [UnlitMaterial(color: .black)])
        island.position = [0, h / 2 - spec.bezel - 0.0062, d / 2 + 0.0004]
        root.addChild(island)

        var lensMat = PhysicallyBasedMaterial()
        lensMat.baseColor = .init(tint: NSColor(white: 0.03, alpha: 1))
        lensMat.metallic = 0.6
        lensMat.roughness = 0.08
        lensMat.clearcoat = 1.0
        func lens(_ p: SIMD3<Float>, r: Float = 0.0062) {
            let l = ModelEntity(mesh: .generateCylinder(height: 0.0022, radius: r), materials: [lensMat])
            l.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            l.position = p
            root.addChild(l)
        }

        switch spec.camera {
        case .proPlateau:
            let c = SIMD3<Float>(-w / 2 + 0.0205, h / 2 - 0.021, -d / 2 - 0.0012)
            let plateau = ModelEntity(mesh: .generateBox(width: 0.034, height: 0.036, depth: 0.0024, cornerRadius: 0.008), materials: [frame])
            plateau.position = c
            root.addChild(plateau)
            for o in [SIMD2<Float>(-0.0075, 0.0085), SIMD2<Float>(-0.0075, -0.0085), SIMD2<Float>(0.0085, 0)] {
                lens(c + SIMD3(o.x, o.y, -0.0018))
            }
        case .airBar:
            // Full-width plateau across the top of the back, single camera on the left.
            let barH: Float = 0.0215
            let c = SIMD3<Float>(0, h / 2 - 0.0075 - barH / 2, -d / 2 - 0.0013)
            let bar = ModelEntity(mesh: .generateBox(width: w - 0.006, height: barH, depth: 0.0026, cornerRadius: barH / 2 - 0.0005),
                                  materials: [frame])
            bar.position = c
            root.addChild(bar)
            lens(c + SIMD3(-w / 2 + 0.0145, 0, -0.0019), r: 0.0068)
            lens(c + SIMD3(-w / 2 + 0.030, 0, -0.0016), r: 0.0022)   // flash
        }

        for (y, bh, side) in [(Float(0.03), Float(0.022), Float(1)), (0.038, 0.012, -1), (0.018, 0.016, -1), (0.0, 0.016, -1)] {
            let b = ModelEntity(mesh: .generateBox(width: 0.0012, height: bh, depth: min(0.0032, d * 0.55), cornerRadius: 0.0005),
                                materials: [frame])
            b.position = [side * (w / 2 + 0.0004), y, 0]
            root.addChild(b)
        }
        return (root, screen)
    }

    @MainActor
    static func placeholderScreen() -> RealityKit.Material {
        let image = NSImage(size: NSSize(width: 256, height: 512), flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.30, alpha: 1),
                                NSColor(calibratedRed: 0.35, green: 0.12, blue: 0.55, alpha: 1),
                                NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.35, alpha: 1)])?.draw(in: rect, angle: 70)
            return true
        }
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let tex = try? TextureResource(image: cg, options: .init(semantic: .color)) {
            var m = UnlitMaterial()
            m.color = .init(texture: .init(tex))
            return m
        }
        return UnlitMaterial(color: .darkGray)
    }

    @MainActor
    static func videoMaterial(_ tex: TextureResource) -> RealityKit.Material {
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex))
        return m
    }
}
