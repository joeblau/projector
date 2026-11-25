import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

/// Video-only presentation: the phone's screen, aspect-fit on black, updated on the display's refresh.
struct PureScreenView: NSViewRepresentable {
    let video: VideoFrameStore
    func makeNSView(context: Context) -> PureScreenNSView { PureScreenNSView(video: video) }
    func updateNSView(_ nsView: PureScreenNSView, context: Context) {}
}

final class PureScreenNSView: NSView {
    private let video: VideoFrameStore
    private let videoLayer = CALayer()
    private var generation = 0
    private var link: CADisplayLink?

    init(video: VideoFrameStore) {
        self.video = video
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }

    @objc private func tick() {
        guard let (pb, gen) = video.frame(newerThan: generation) else { return }
        generation = gen
        // The decoder's buffers are IOSurface-backed, so this is zero-copy.
        videoLayer.contents = pb.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
    }

    deinit { link?.invalidate() }
}
