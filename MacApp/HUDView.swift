import SwiftUI
import simd

@MainActor @Observable
final class HUDModel {
    var snap = TelemetryHub.Snapshot()
    var video = VideoFrameStore.Stats()
}

struct HUDView: View {
    let model: HUDModel
    let onRecenter: () -> Void

    var body: some View {
        let s = model.snap
        VStack {
            HStack(alignment: .top) {
                ConnectionPanel(snap: s, video: model.video)
                Spacer()
                AttitudePanel(snap: s, onRecenter: onRecenter)
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 16) {
                GraphPanel(title: "ROTATION RATE", unit: "rad/s", samples: s.rotationHistory, range: 8)
                GraphPanel(title: "USER ACCELERATION", unit: "g", samples: s.accelHistory, range: 2)
            }
        }
        .padding(28)
        .foregroundStyle(.white)
    }
}

private struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

private struct ConnectionPanel: View {
    let snap: TelemetryHub.Snapshot
    let video: VideoFrameStore.Stats
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(snap.connected ? Color.green : Color.orange).frame(width: 9, height: 9)
                    Text(title).font(.system(size: 17, weight: .semibold))
                }
                Group {
                    if snap.connected {
                        row("Source", snap.activeSource?.label ?? "-")
                        row("Rate", "\(snap.rateHz) Hz")
                        row("Latency", snap.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—")
                        row("Dropped", "\(snap.dropped)")
                        if let st = snap.status {
                            row("Battery", st.batteryLevel >= 0 ? "\(Int(st.batteryLevel * 100))%\(st.batteryState >= 2 ? " ⚡︎" : "")" : "—")
                            row("Thermal", ["Nominal", "Fair", "Serious", "Critical"][min(Int(st.thermalState), 3)])
                            if snap.activeSource == .broadcast, st.memoryMB > 0 {
                                row("Ext memory", String(format: "%.1f / 50 MB", st.memoryMB))
                            }
                        }
                        if let body = snap.bodyName { row("Model", body) }
                        if video.connected {
                            Divider().overlay(.white.opacity(0.15))
                            row("Video", video.source.map { "\($0.rawValue) \(video.width)×\(video.height)" } ?? "waiting…")
                            row("Video fps", "\(video.fps)")
                            if video.source == .network {
                                row("Bitrate", String(format: "%.1f Mbps", Double(video.kbps) / 1000))
                                row("Video lat.", video.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—")
                            }
                        }
                    } else {
                        Text(snap.listenerState).foregroundStyle(.secondary)
                        Text("Open Projector on your iPhone").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
            }
            .frame(width: 230, alignment: .leading)
        }
    }
    private var title: String {
        if snap.connected { return snap.status?.deviceName ?? "iPhone" }
        return "Waiting for iPhone"
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
    }
}

private struct AttitudePanel: View {
    let snap: TelemetryHub.Snapshot
    let onRecenter: () -> Void
    var body: some View {
        Panel {
            VStack(alignment: .trailing, spacing: 8) {
                let e = eulerDegrees(snap.motion?.gravity)
                Text("ATTITUDE").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                Group {
                    Text(String(format: "pitch %+6.1f°", e.pitch))
                    Text(String(format: "roll  %+6.1f°", e.roll))
                    if let m = snap.motion {
                        let g = m.gravity
                        Text(String(format: "g  %+.2f %+.2f %+.2f", g.x, g.y, g.z)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 15, design: .monospaced))
                Text("smoothing: \(snap.smoothing.label)  (S)")
                    .font(.system(size: 12, design: .monospaced))
                Text("scroll/pinch zoom · drag pan · 0 reset\nF pure screen · H hide overlay")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Button("Recenter  ⌘R", action: onRecenter)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
    }
    /// Pitch/roll from the gravity vector (device frame) — independent of arbitrary yaw.
    private func eulerDegrees(_ g: SIMD3<Float>?) -> (pitch: Float, roll: Float) {
        guard let g else { return (0, 0) }
        let pitch = atan2(-g.z, -g.y) * 180 / .pi     // 0 = upright, +90 = flat face up
        let roll = atan2(g.x, sqrt(g.y * g.y + g.z * g.z)) * 180 / .pi
        return (pitch, roll)
    }
}

private struct GraphPanel: View {
    let title: String
    let unit: String
    let samples: [SIMD3<Float>]
    let range: Float
    private let colors: [Color] = [.init(red: 1, green: 0.35, blue: 0.35), .init(red: 0.35, green: 0.9, blue: 0.45), .init(red: 0.4, green: 0.6, blue: 1)]

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                    if let last = samples.last {
                        ForEach(0..<3, id: \.self) { i in
                            Text(String(format: "%@ %+.2f", ["x", "y", "z"][i], last[i]))
                                .foregroundStyle(colors[i])
                        }
                        Text(unit).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                Canvas { ctx, size in
                    let mid = size.height / 2
                    ctx.stroke(Path { $0.move(to: .init(x: 0, y: mid)); $0.addLine(to: .init(x: size.width, y: mid)) },
                               with: .color(.white.opacity(0.12)), lineWidth: 1)
                    guard samples.count > 1 else { return }
                    let step = size.width / CGFloat(TelemetryHub.historyLength - 1)
                    let startX = size.width - CGFloat(samples.count - 1) * step
                    for axis in 0..<3 {
                        var p = Path()
                        for (i, v) in samples.enumerated() {
                            let y = mid - CGFloat(max(-1, min(1, v[axis] / range))) * mid
                            let pt = CGPoint(x: startX + CGFloat(i) * step, y: y)
                            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                        }
                        ctx.stroke(p, with: .color(colors[axis]), lineWidth: 1.6)
                    }
                }
                .frame(height: 110)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
