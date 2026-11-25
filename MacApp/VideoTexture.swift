import CoreVideo
import Metal
import RealityKit

/// Copies decoded CVPixelBuffers into a RealityKit LowLevelTexture on the GPU (no CPU copies).
@MainActor
final class VideoTexture {
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var cache: CVMetalTextureCache?
    private var texture: LowLevelTexture?
    private(set) var resource: TextureResource?
    private var size = (0, 0)

    init() { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }

    /// Returns a new TextureResource when the size changed (the caller must rebuild the material).
    func update(with pb: CVPixelBuffer) -> TextureResource? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var created: TextureResource?
        if texture == nil || size != (w, h) {
            let desc = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h,
                                                  textureUsage: [.shaderRead, .shaderWrite])
            guard let t = try? LowLevelTexture(descriptor: desc), let r = try? TextureResource(from: t) else { return nil }
            texture = t; resource = r; size = (w, h); created = r
        }
        guard let cache, let texture else { return created }
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm_srgb, w, h, 0, &cvTex)
        guard let cvTex, let src = CVMetalTextureGetTexture(cvTex), let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return created }
        let dst = texture.replace(using: cb)
        blit.copy(from: src, to: dst)
        blit.endEncoding()
        cb.addCompletedHandler { _ in _ = cvTex }   // keep the CVMetalTexture alive until the GPU is done
        cb.commit()
        return created
    }
}
