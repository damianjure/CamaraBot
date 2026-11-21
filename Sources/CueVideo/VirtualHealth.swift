import SwiftUI

/// What is wrong with a running virtual camera, in words an operator can act on.
enum VirtualHealth {
    /// Seconds after a camera starts before a missing picture counts as a fault.
    static let grace = 4.0
    /// The share of recently sent frames dropped before it is worth saying, once enough have gone out.
    static let dropShare = 0.05
    static let dropSample = 300
    /// How far back "recently" reaches, in seconds.
    static let dropWindow = 30.0

    /// Empty when all is well.
    static func problems(_ s: VirtualCameraRuntime.Status, age: TimeInterval) -> [String] {
        guard age >= grace else { return [] }
        var out: [String] = []
        if !s.captureLive { out.append(s.problem ?? "no picture from the capture device") }
        if s.runtimeMissing {
            out.append("NDI isn't installed on this Mac")
        } else if s.captureLive, !s.outputLive {
            out.append("not sending over NDI")
        } else if s.recentSent >= dropSample, Double(s.recentDropped) / Double(s.recentSent) > dropShare {
            out.append(String(format: "dropping frames (%.0f%%)", 100 * Double(s.recentDropped) / Double(s.recentSent)))
        }
        return out
    }
}

extension VirtualCameraRuntime.Status {
    /// What the camera is doing, in words for the operator: used by the operator tile and by Setup.
    var steeringText: String {
        switch mode {
        case "follow":
            switch phase {
            case "following": return "Following a person"
            case "searching": return "Looking for them"
            case "lost": return "Lost sight, showing the whole picture"
            default: return "Waiting for someone in the picture"
            }
        case "wide": return "Wide"
        case "hold": return "Held"
        default: return "At a saved shot"
        }
    }
}

/// Frames sent and dropped over the last `VirtualHealth.dropWindow` seconds, from counters that
/// only ever grow. A burst at start-up stops counting once it is older than the window, and a new
/// problem shows up without waiting for a whole run's worth of good frames to be outweighed.
struct DropWindow {
    private var samples: [(time: Date, sent: Int, dropped: Int)] = []

    /// Records the counters as they are now and returns what happened within the window.
    mutating func add(now: Date, sent: Int, dropped: Int) -> (sent: Int, dropped: Int) {
        if let last = samples.last, sent < last.sent || dropped < last.dropped { samples.removeAll() }  // counters restarted
        samples.append((now, sent, dropped))
        // Keep one sample at or before the window's start, so the span covers the whole window.
        while samples.count > 2, now.timeIntervalSince(samples[1].time) >= VirtualHealth.dropWindow { samples.removeFirst() }
        guard let first = samples.first else { return (0, 0) }
        return (sent - first.sent, dropped - first.dropped)
    }
}

/// A red line on the main screens when a virtual camera that should be sending has stopped, so a
/// pulled cable or a dead NDI output is seen from Operate and not only by opening Setup.
struct VirtualCameraBanner: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let faults = VirtualCameras.shared.all.compactMap { r -> String? in
                let p = VirtualHealth.problems(r.status(), age: r.age)
                return p.isEmpty ? nil : "\(r.camera.name): \(p.joined(separator: ", "))"
            }
            if !faults.isEmpty {
                Text(faults.joined(separator: "  ·  "))
                    .font(.sans(13, .semibold)).foregroundStyle(.white).lineLimit(2)
                    .padding(.horizontal, T.s4).padding(.vertical, T.s2)
                    .background(Capsule().fill(T.danger)).padding(.top, T.s3)
                    .help(tr("A virtual camera isn't sending. Details are in Status.", es: "Una cámara virtual no está enviando. El detalle está en Status."))
            }
        }
    }
}

/// Status page: one card for each virtual camera that is running.
struct VirtualStatusSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text("Virtual cameras").panelLabel()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let cams = VirtualCameras.shared.all
                if cams.isEmpty {
                    Text(tr("None running. Add or switch one on in Setup > Virtual cameras.", es: "No hay ninguna en marcha. Agregá o encendé una en Setup > Virtual cameras.")).font(.sans(12)).foregroundStyle(T.inkSubtle)
                } else {
                    VStack(alignment: .leading, spacing: T.s3) {
                        ForEach(Array(stride(from: 0, to: cams.count, by: 3)), id: \.self) { start in
                            HStack(alignment: .top, spacing: T.s3) {
                                ForEach(cams[start..<min(start + 3, cams.count)], id: \.camera.id) { r in
                                    Card(title: r.camera.name) { rows(StatusReport.virtualRows(r).dropFirst()) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func rows(_ rows: ArraySlice<(String, String)>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: T.s3) {
                    Text(row.0).font(.sans(12)).foregroundStyle(T.inkSubtle).frame(width: 90, alignment: .leading)
                    Text(row.1).font(.sans(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
