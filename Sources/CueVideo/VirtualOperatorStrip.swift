import SwiftUI

/// Operate page: one tile per running virtual camera. It shows the whole captured picture with the
/// crop drawn on it (what goes out over NDI), and the buttons to steer it: the shot to follow
/// (Close, Waist, Full), Follow, Wide and Hold.
struct VirtualOperatorStrip: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let cams = store.config.virtualCameras.filter(\.enabled)
        if !cams.isEmpty {
            VStack(alignment: .leading, spacing: T.s2) {
                ForEach(cams) { cam in VirtualOperatorTile(cam: cam) }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct VirtualOperatorTile: View {
    let cam: VirtualCamera
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        // Refreshed a few times a second: the picture, the crop and the mode.
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let runtime = VirtualCameras.shared.runtime(for: cam.id)
            let status = runtime?.status()
            HStack(alignment: .center, spacing: T.s4) {
                picture(runtime, status)
                VStack(alignment: .leading, spacing: T.s2) {
                    HStack(spacing: T.s2) {
                        Text(cam.name).font(.sans(13, .semibold)).foregroundStyle(T.ink).lineLimit(1)
                        Text(statusText(status)).font(.sans(12)).foregroundStyle(T.inkSubtle).lineLimit(1)
                    }
                    HStack(spacing: T.s2) {
                        ForEach(ShotSize.allCases) { size in
                            button(size.short, active: status?.mode == "follow" && status?.shot == size.rawValue) {
                                setShot(size)
                                runtime?.followPerson()
                            }
                        }
                        Rectangle().fill(T.line).frame(width: 1, height: 22)
                        button("Follow", active: status?.mode == "follow") { runtime?.followPerson() }
                        button("Wide", active: status?.mode == "wide") { runtime?.wide() }
                        button("Hold", active: status?.mode == "hold") { runtime?.hold() }
                    }
                    if !cam.shots.isEmpty {
                        HStack(spacing: T.s2) {
                            ForEach(cam.shots) { shot in
                                button(shot.name, active: false) { runtime?.go(to: shot) }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The full picture with the crop drawn on it.
    private func picture(_ runtime: VirtualCameraRuntime?, _ status: VirtualCameraRuntime.Status?) -> some View {
        ZStack {
            Color.black
            if let image = runtime?.preview() {
                GeometryReader { g in
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: g.size.width, height: g.size.height)
                        if let c = status?.crop { CropOutline(crop: c, size: g.size) }
                    }
                }
            } else {
                Text(runtime == nil ? "Starting…" : "Waiting for the picture").font(.sans(11)).foregroundStyle(T.inkSubtle)
            }
        }
        .frame(width: 192, height: 108)
        .clipShape(Rectangle())
        .overlay(Rectangle().stroke(T.line))
    }

    private func statusText(_ s: VirtualCameraRuntime.Status?) -> String {
        guard let s else { return "Starting…" }
        if !s.captureLive { return s.problem ?? "No picture" }
        switch s.mode {
        case "follow":
            switch s.phase {
            case "following": return "Following a person"
            case "searching": return "Looking for them"
            case "lost": return "Lost sight, showing the whole picture"
            default: return "Waiting for someone"
            }
        case "wide": return "Wide"
        case "hold": return "Held"
        default: return "At a saved shot"
        }
    }

    private func setShot(_ size: ShotSize) {
        store.update { c in
            if let i = c.virtualCameras.firstIndex(where: { $0.id == cam.id }) { c.virtualCameras[i].shotSize = size.rawValue }
        }
    }

    private func button(_ title: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(CueButton(kind: active ? .primary : .secondary))
    }
}

/// The crop (0 to 1, from the top left) drawn over the picture, with the rest dimmed.
struct CropOutline: View {
    let crop: CropRect
    let size: CGSize

    var body: some View {
        let r = CGRect(x: crop.x * size.width, y: crop.y * size.height, width: crop.w * size.width, height: crop.h * size.height)
        ZStack {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle().stroke(T.accent, lineWidth: 2).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
        }
        .allowsHitTesting(false)
    }
}
