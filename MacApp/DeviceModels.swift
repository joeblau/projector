import AppKit
import RealityKit

/// Maps a device model identifier to an Apple AR Quick Look model (downloaded from apple.com product pages),
/// and normalizes it so its local axes match CoreMotion's device frame: +X right, +Y top, +Z out of the screen.
///
/// Models are loaded from ~/Library/Application Support/Projector/Models (or $PROJECTOR_MODELS) and are
/// deliberately not bundled: they're Apple's assets, fine for a personal rig but not for redistribution.
@MainActor
enum DeviceModels {
    /// Only devices Apple currently publishes a standalone AR model for.
    static let catalog: [String: (file: String, name: String)] = [
        "iPhone18,4": ("iphone-air-e-sim.usdz", "iPhone Air"),
        "iPhone18,3": ("iphone-17-e-sim.usdz", "iPhone 17"),
        "iPad15,7": ("ipad-11-silver.usdz", "iPad (A16)"),
        "iPad15,8": ("ipad-11-silver.usdz", "iPad (A16)"),
    ]

    static var folder: URL {
        if let p = ProcessInfo.processInfo.environment["PROJECTOR_MODELS"] { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projector/Models")
    }

    struct Body {
        let root: Entity
        let screen: ModelEntity
        let displayName: String
    }

    private static var cache: [String: Body] = [:]

    /// Returns a fresh body for `identifier`: the Apple model when available, otherwise the procedural phone.
    static func body(for identifier: String?) async -> Body {
        if let id = identifier, let entry = catalog[id] {
            if let cached = cache[entry.file] { return clone(cached) }
            let url = folder.appendingPathComponent(entry.file)
            if FileManager.default.fileExists(atPath: url.path),
               let raw = try? await Entity(contentsOf: url),
               let body = normalize(raw, name: entry.name) {
                cache[entry.file] = body
                return clone(body)
            }
            NSLog("[models] couldn't load \(url.lastPathComponent); falling back to procedural body")
        }
        let spec = PhoneSpec.forModel(identifier)
        let (root, screen) = PhoneEntity.make(spec)
        return Body(root: root, screen: screen, displayName: spec.name)
    }

    private static func clone(_ b: Body) -> Body {
        let root = b.root.clone(recursive: true)
        let screen = root.findEntity(named: "projector-screen") as? ModelEntity ?? b.screen
        return Body(root: root, screen: screen, displayName: b.displayName)
    }

    /// Finds the display mesh, rotates the model into the device frame, hides Apple's wallpaper and adds
    /// a plane (with clean UVs) for the live video just above the front glass.
    private static func normalize(_ raw: Entity, name: String) -> Body? {
        let bounds = raw.visualBounds(relativeTo: nil)

        // 1. The display: the largest flat mesh with an emissive or shader-graph (wallpaper) material.
        var best: (entity: Entity, box: BoundingBox, area: Float)?
        func walk(_ e: Entity) {
            if let model = e.components[ModelComponent.self] {
                let box = e.visualBounds(relativeTo: nil)
                let ext = [box.extents.x, box.extents.y, box.extents.z].sorted()
                let flat = ext[0] < ext[1] * 0.12
                let looksLikeScreen = model.materials.contains { m in
                    if m is ShaderGraphMaterial { return true }
                    if let p = m as? PhysicallyBasedMaterial { return p.emissiveColor.texture != nil }
                    return false
                }
                let area = ext[1] * ext[2]
                if flat, looksLikeScreen, area > (best?.area ?? 0) { best = (e, box, area) }
            }
            e.children.forEach(walk)
        }
        walk(raw)
        guard let screen = best else { return nil }

        // 2. Axes from the display's shape: thinnest = screen normal, longest = height.
        let se = screen.box.extents
        let axes = [0, 1, 2].sorted { se[$0] < se[$1] }
        let (normalAxis, widthAxis, heightAxis) = (axes[0], axes[1], axes[2])
        // The camera bump sits on the back, which pushes the overall bounds' center behind the display.
        let frontSign: Float = screen.box.center[normalAxis] >= bounds.center[normalAxis] ? 1 : -1
        func unit(_ axis: Int, _ sign: Float) -> SIMD3<Float> { var v = SIMD3<Float>.zero; v[axis] = sign; return v }
        let front = unit(normalAxis, frontSign)
        let up = unit(heightAxis, 1)                        // Apple's AR models stand upright in +Y / +height
        let right = simd_cross(up, front)
        _ = widthAxis
        // Rows = where each model axis goes in the device frame.
        let toDevice = simd_quatf(simd_float3x3(rows: [right, up, front]))

        let container = Entity()
        raw.orientation = toDevice
        raw.position = -toDevice.act(bounds.center)
        container.addChild(raw)

        // 3. Video surface, sized to the display, floating 0.1 mm above the front glass.
        let devExt = abs(toDevice.act(bounds.extents))
        let w = se[widthAxis], h = se[heightAxis]
        let center = toDevice.act(screen.box.center - bounds.center)
        let plane = ModelEntity(mesh: .generatePlane(width: w, height: h, cornerRadius: min(w, h) * 0.12),
                                materials: [PhoneEntity.placeholderScreen()])
        plane.name = "projector-screen"
        plane.position = SIMD3(center.x, center.y, devExt.z / 2 + 0.0001)
        container.addChild(plane)
        screen.entity.isEnabled = false

        NSLog("[models] \(name): device \(devExt) display \(w)×\(h) front=\(frontSign > 0 ? "+" : "-")\(["X", "Y", "Z"][normalAxis])")
        return Body(root: container, screen: plane, displayName: name)
    }
}
