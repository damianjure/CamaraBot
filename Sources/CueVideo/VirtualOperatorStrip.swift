import SwiftUI

/// Operate page: one tile per running virtual camera. It shows the whole captured picture with the
/// crop drawn on it (what goes out over NDI), and the buttons to steer it: the shot to follow
/// (Close, Waist, Full), Follow, Wide and Hold.
struct VirtualOperatorStrip: View {
    /// Large: a grid of big cards that grows with the cameras (Operate without a switcher).
    /// Small: one row of compact tiles that scrolls sideways (under the switcher's sources).
    var large = false
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let cams = store.config.virtualCameras.filter(\.enabled)
        if !cams.isEmpty {
            if large {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: T.s3, alignment: .top)], alignment: .leading, spacing: T.s3) {
                    ForEach(cams) { cam in VirtualOperatorTile(cam: cam, large: true) }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: T.s4) {
                        ForEach(cams) { cam in VirtualOperatorTile(cam: cam, large: false) }
                    }
                }
            }
        }
    }
}

struct VirtualOperatorTile: View {
    let cam: VirtualCamera
    var large = false
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        // Refreshed a few times a second: the picture, the crop and the mode.
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let runtime = VirtualCameras.shared.runtime(for: cam.id)
            let status = runtime?.status()
            let info = VStack(alignment: .leading, spacing: T.s2) {
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
                HStack(spacing: T.s2) {
                    button("Zoom +", active: false) { runtime?.zoomManually(by: 0.85) }
                    button("Zoom −", active: false) { runtime?.zoomManually(by: 1 / 0.85) }
                    button("Save shot", active: false) { saveShot(runtime) }
                        .help(tr("Saves the crop as it is now, to go back to with one click", es: "Guarda el recorte como está ahora, para volver con un clic"))
                    Text(tr("Drag on the picture to frame it by hand", es: "Arrastrá sobre la imagen para encuadrar a mano")).font(.sans(11)).foregroundStyle(T.inkSubtle).lineLimit(1)
                }
                if !cam.shots.isEmpty {
                    HStack(spacing: T.s2) {
                        ForEach(cam.shots) { shot in
                            button(shot.name, active: false) { runtime?.go(to: shot) }
                                .contextMenu { Button(tr("Remove \(shot.name)", es: "Quitar \(shot.name)"), role: .destructive) { removeShot(shot) } }
                        }
                    }
                }
            }
            if large {
                VStack(alignment: .leading, spacing: T.s3) {
                    picture(runtime, status)
                    info
                }
                .padding(T.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: T.rMD).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line))
            } else {
                HStack(alignment: .center, spacing: T.s4) {
                    picture(runtime, status)
                    info
                }
            }
        }
    }

    /// The full picture with the crop drawn on it, and the people found in it: click one to follow them.
    private func picture(_ runtime: VirtualCameraRuntime?, _ status: VirtualCameraRuntime.Status?) -> some View {
        ZStack {
            Color.black
            if let image = runtime?.preview() {
                GeometryReader { g in
                    let imageSize = CGSize(width: image.width, height: image.height)
                    let area = PictureGeometry.fitted(imageSize, in: g.size)
                    let people: (all: [CGRect], followed: CGRect?) = runtime?.peopleSeen() ?? (all: [], followed: nil)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable().frame(width: area.width, height: area.height)
                            .position(x: area.midX, y: area.midY)
                        if let c = status?.crop { CropOutline(crop: c, area: area) }
                        PeopleOutlines(people: people.all, followed: people.followed, area: area)
                    }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        if let p = PictureGeometry.normalized(tap.location, image: imageSize, in: g.size) { runtime?.followPerson(at: p) }
                    })
                    // Dragging puts the crop where the pointer is, and holds it there.
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { drag in
                        if let p = PictureGeometry.normalized(drag.location, image: imageSize, in: g.size) {
                            runtime?.frameManually(centerX: p.x, centerY: p.y)
                        }
                    })
                    .help(tr("Click a person to follow them. Drag to frame by hand.", es: "Clic en una persona para seguirla. Arrastrá para encuadrar a mano."))
                }
            } else {
                Text(runtime == nil ? "Starting…" : "Waiting for the picture").font(.sans(11)).foregroundStyle(T.inkSubtle)
            }
        }
        .frame(width: large ? nil : 192, height: large ? nil : 108)
        .frame(maxWidth: large ? .infinity : nil)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(Rectangle())
        .overlay(Rectangle().stroke(T.line))
    }

    private func statusText(_ s: VirtualCameraRuntime.Status?) -> String {
        guard let s else { return "Starting…" }
        if !s.captureLive { return s.problem ?? "No picture" }
        return s.steeringText
    }

    private func saveShot(_ runtime: VirtualCameraRuntime?) {
        guard let runtime else { return }
        let crop = runtime.currentCrop()
        store.update { c in
            guard let i = c.virtualCameras.firstIndex(where: { $0.id == cam.id }) else { return }
            c.virtualCameras[i].shots.append(CropShot(name: c.virtualCameras[i].nextShotName, crop: crop))
        }
    }

    private func removeShot(_ shot: CropShot) {
        store.update { c in
            guard let i = c.virtualCameras.firstIndex(where: { $0.id == cam.id }) else { return }
            c.virtualCameras[i].shots.removeAll { $0.id == shot.id }
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

/// Where a picture of any shape sits inside a box that shows it whole (letterboxed), and how a
/// click in the box maps back onto the picture.
enum PictureGeometry {
    static func fitted(_ image: CGSize, in box: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return CGRect(origin: .zero, size: box) }
        let scale = min(box.width / image.width, box.height / image.height)
        let w = image.width * scale, h = image.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// A point in the box as 0 to 1 across the picture from its top left, or nil when it falls outside the picture.
    static func normalized(_ point: CGPoint, image: CGSize, in box: CGSize) -> CGPoint? {
        let r = fitted(image, in: box)
        guard r.width > 0, r.height > 0, r.contains(point) else { return nil }
        return CGPoint(x: (point.x - r.minX) / r.width, y: (point.y - r.minY) / r.height)
    }
}

/// The crop (0 to 1, from the top left of the picture) drawn over it, with the rest dimmed.
struct CropOutline: View {
    let crop: CropRect
    let area: CGRect

    var body: some View {
        let r = CGRect(x: area.minX + crop.x * area.width, y: area.minY + crop.y * area.height,
                       width: crop.w * area.width, height: crop.h * area.height)
        ZStack {
            Path { p in
                p.addRect(area)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle().stroke(T.accent, lineWidth: 2).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
        }
        .allowsHitTesting(false)
    }
}

/// A thin box around each person found, the followed one brighter.
struct PeopleOutlines: View {
    let people: [CGRect]
    let followed: CGRect?
    let area: CGRect

    var body: some View {
        ZStack {
            ForEach(people.indices, id: \.self) { i in
                let b = people[i]
                let on = followed.map { $0 == b } ?? false
                let r = CGRect(x: area.minX + b.minX * area.width, y: area.minY + b.minY * area.height,
                               width: b.width * area.width, height: b.height * area.height)
                Rectangle().stroke(on ? T.success : Color.white.opacity(0.55), lineWidth: on ? 2 : 1)
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            }
        }
        .allowsHitTesting(false)
    }
}
