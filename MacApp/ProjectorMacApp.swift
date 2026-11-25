import AppKit
import SwiftUI

@main
struct ProjectorMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var hud = HUDModel()
    @State private var controls = StageControls()
    private let hub: TelemetryHub
    private let receiver: TelemetryReceiver
    private let video = VideoFrameStore()
    private let videoReceiver: VideoReceiver
    private let usbCapture: USBScreenCapture

    init() {
        let hub = TelemetryHub()
        self.hub = hub
        receiver = TelemetryReceiver(hub: hub)
        receiver.start()
        videoReceiver = VideoReceiver(store: video)
        videoReceiver.start()
        usbCapture = USBScreenCapture(store: video, preferredName: { hub.deviceName() })
        if ProcessInfo.processInfo.environment["PROJECTOR_NO_USB"] == nil { usbCapture.start() }
    }

    var body: some Scene {
        WindowGroup("Projector") {
            ZStack {
                RadialGradient(colors: [Color(white: 0.16), Color(white: 0.03)], center: .center, startRadius: 50, endRadius: 900)
                    .ignoresSafeArea()
                StageView(hub: hub, video: video, controls: controls)
                    .modifier(StageInput(controls: controls))
                    .ignoresSafeArea()
                if controls.showHUD && !controls.pureScreen {
                    HUDView(model: hud, onRecenter: hub.requestRecenter)
                }
                if controls.pureScreen {
                    PureScreenView(video: video).ignoresSafeArea()
                    if !hud.video.connected || hud.video.width == 0 {
                        Text("Waiting for screen — start the broadcast on your iPhone")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .onChange(of: controls.pureScreen) { _, pure in
                if pure { NSCursor.setHiddenUntilMouseMoves(true) }
                // Pure mode always means the whole display.
                if pure, let w = NSApp.keyWindow ?? NSApp.windows.first, !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            }
            .frame(minWidth: 960, minHeight: 600)
            .task {
                // HUD refresh at 30 Hz; the 3D view reads the hub every frame on its own.
                var tick = 0
                while !Task.isCancelled {
                    hud.snap = hub.snapshot(); hud.video = video.snapshot()
                    tick += 1
                    if tick % 60 == 0 {   // every ~5 s: lets us verify the pipeline headlessly
                        let v = hud.video, s = hud.snap
                        NSLog("[stats] motion \(s.rateHz)Hz src=\(s.activeSource?.label ?? "-") body=\(s.bodyName ?? "-") | video \(v.source?.rawValue ?? "none") \(v.width)x\(v.height) \(v.fps)fps \(v.kbps)kbps usb=\(v.usbDevice ?? "-") | phone: rpFrames=\(s.status?.videoFrameHz ?? 0)/s mem=\(String(format: "%.1f", s.status?.memoryMB ?? -1))MB")
                    }
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Phone") {
                Button("Recenter", action: hub.requestRecenter).keyboardShortcut("r")
                Button("Cycle Smoothing (Off/Light/Medium/Heavy)") { hub.smoothingLevel = hub.smoothingLevel.next }
                    .keyboardShortcut("s", modifiers: [])
            }
            CommandMenu("Stage") {
                Button(controls.pureScreen ? "Exit Pure Screen" : "Pure Screen") { controls.pureScreen.toggle() }
                    .keyboardShortcut("f", modifiers: [])
                Button(controls.showHUD ? "Hide Overlay" : "Show Overlay") { controls.showHUD.toggle() }
                    .keyboardShortcut("h", modifiers: [])
                Divider()
                Button("Zoom In") { controls.step(zoomIn: true) }.keyboardShortcut("=", modifiers: [])
                Button("Zoom Out") { controls.step(zoomIn: false) }.keyboardShortcut("-", modifiers: [])
                Button("Reset View") { controls.resetView() }.keyboardShortcut("0", modifiers: [])
                Divider()
                Button("Exit Pure Screen") { controls.pureScreen = false }.keyboardShortcut(.escape, modifiers: [])
                    .disabled(!controls.pureScreen)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["PROJECTOR_WINDOWED"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.windows.first?.toggleFullScreen(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
