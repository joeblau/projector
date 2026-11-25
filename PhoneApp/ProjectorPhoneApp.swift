import ReplayKit
import simd
import SwiftUI

@main
struct ProjectorPhoneApp: App {
    var body: some Scene { WindowGroup { PhoneView() } }
}

@MainActor
final class PhoneModel: ObservableObject {
    @Published var linkState: MacLink.State = .searching
    @Published var streaming = false
    @Published var attitude = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    @Published var userAccel = SIMD3<Float>.zero

    private var streamer: TelemetryStreamer?
    private var lastUI = Date.distantPast

    func setStreaming(_ on: Bool) {
        if on, streamer == nil {
            let s = TelemetryStreamer(source: .app)
            s.link.onStateChange = { [weak self] st in Task { @MainActor in self?.linkState = st } }
            s.onSample = { [weak self] p in
                Task { @MainActor in
                    guard let self, Date().timeIntervalSince(self.lastUI) > 1.0 / 20 else { return }
                    self.lastUI = Date(); self.attitude = p.attitude; self.userAccel = p.userAcceleration
                }
            }
            s.start()
            streamer = s
        } else if !on {
            streamer?.stop(); streamer = nil
            linkState = .searching
        }
        streaming = on
    }
}

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        v.preferredExtension = "com.joeblau.projector.broadcast"
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct PhoneView: View {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Stream while app is open", isOn: Binding(get: { model.streaming }, set: model.setStreaming))
                    LabeledContent("Mac", value: linkText)
                } footer: {
                    Text("Streams 100 Hz motion to the Projector app on your Mac. Stops when you leave this app.")
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Broadcast over any app").font(.headline)
                            Text("Keeps streaming while you use other apps. Tap, choose Projector Broadcast, then Start.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        BroadcastPicker().frame(width: 64, height: 64)
                    }
                }

                if model.streaming {
                    Section("Live") {
                        let v = model.attitude.vector
                        LabeledContent("Attitude", value: String(format: "%.2f %.2f %.2f %.2f", v.x, v.y, v.z, v.w))
                        LabeledContent("User accel (g)", value: String(format: "%.2f %.2f %.2f",
                                                                        model.userAccel.x, model.userAccel.y, model.userAccel.z))
                    }.font(.footnote.monospaced())
                }
            }
            .navigationTitle("Projector")
        }
        .onAppear { model.setStreaming(true) }
        .onChange(of: phase) { _, p in
            // The app process is suspended in the background; the broadcast extension takes over there.
            if p == .background { model.setStreaming(false) }
        }
    }

    private var linkText: String {
        switch model.linkState {
        case .searching: return model.streaming ? "Searching…" : "Idle"
        case .connecting(let n): return "Connecting to \(n)…"
        case .ready(let n): return "● \(n)"
        case .failed(let e): return e
        }
    }
}
