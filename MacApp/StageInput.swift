import AppKit
import SwiftUI

/// Scroll-wheel / trackpad pinch zoom toward the cursor, and drag to pan, for the 3D stage.
struct StageInput: ViewModifier {
    let controls: StageControls
    @State private var monitor: Any?
    @State private var lastDrag: CGSize = .zero

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .onAppear { install() }
                .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
                .onChange(of: geo.size, initial: true) { _, s in
                    if s.height > 0 { controls.viewportAspect = Float(s.width / s.height) }
                }
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        let d = CGSize(width: v.translation.width - lastDrag.width, height: v.translation.height - lastDrag.height)
                        lastDrag = v.translation
                        controls.pan(by: d, in: geo.size)
                    }
                    .onEnded { _ in lastDrag = .zero })
                .onTapGesture(count: 2) { controls.resetView() }
        }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard !controls.pureScreen, let view = event.window?.contentView else { return event }
            let p = view.convert(event.locationInWindow, from: nil)
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return event }
            let cursor = SIMD2(Float(p.x / size.width) * 2 - 1, Float(p.y / size.height) * 2 - 1)  // AppKit y is up
            switch event.type {
            case .magnify:
                controls.zoom(by: Float(1 - event.magnification), at: cursor)
            case .scrollWheel:
                let dy = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
                controls.zoom(by: exp(-dy), at: cursor)
            default: break
            }
            return nil
        }
    }
}
