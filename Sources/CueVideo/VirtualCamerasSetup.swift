import SwiftUI

/// Setup > Virtual cameras: each fixed USB camera that follows a person by cropping its picture
/// and goes out over NDI. Every choice is a switch, a menu or a control, and takes effect at once;
/// the live status under each camera says what the capture box and the NDI output are doing.
struct VirtualCamerasSetup: View {
    @EnvironmentObject var store: ConfigStore
    @State private var devices: [CaptureDeviceInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: T.s4) {
            if store.config.virtualCameras.isEmpty {
                Card {
                    Text(devices.isEmpty ? "No capture device found. Plug in the capture box, then press Refresh devices."
                                         : "No virtual cameras yet. Add one to start.")
                        .font(.sans(13)).foregroundStyle(T.inkMuted)
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
            ForEach(store.config.virtualCameras) { cam in
                VirtualCameraCard(cam: cam, devices: devices).frame(maxWidth: 760, alignment: .leading)
            }
            HStack(spacing: T.s2) {
                Button { add() } label: { Label("Add a virtual camera", systemImage: "plus") }
                    .buttonStyle(CueButton(kind: .primary)).disabled(devices.isEmpty)
                Button { devices = CaptureFeed.devices() } label: { Label("Refresh devices", systemImage: "arrow.clockwise") }
                    .buttonStyle(CueButton())
                Text("\(devices.count) capture device\(devices.count == 1 ? "" : "s") found").font(.sans(12)).foregroundStyle(T.inkSubtle)
            }
            Text("Only external capture devices are offered: this Mac's own camera can't be sent out as an NDI source.")
                .font(.sans(12)).foregroundStyle(T.inkSubtle)
        }
        .onAppear { devices = CaptureFeed.devices() }
    }

    private func add() {
        guard let d = devices.first else { return }
        let n = store.config.virtualCameras.count + 1
        store.update {
            var cam = VirtualCamera(name: "Virtual camera \(n)", device: d.id, ndiName: "Virtual camera \(n)")
            cam.deviceName = d.name
            $0.virtualCameras.append(cam)
        }
    }
}

struct VirtualCameraCard: View {
    let cam: VirtualCamera
    let devices: [CaptureDeviceInfo]
    @EnvironmentObject var store: ConfigStore
    @State private var nameDraft = ""
    @State private var ndiDraft = ""
    @State private var zoomDraft = 2.5
    @FocusState private var focus: Field?
    private enum Field { case name, ndi }

    /// Changes this camera in the setup. Anything that doesn't need the capture reopened (the name,
    /// shot size, saved shots) is applied to the running camera without a gap in the picture.
    private func edit(_ change: @escaping (inout VirtualCamera) -> Void) {
        store.update { c in
            if let i = c.virtualCameras.firstIndex(where: { $0.id == cam.id }) { change(&c.virtualCameras[i]) }
        }
    }

    /// The device it uses: by its saved ID, or by name when the ID changed (another USB port).
    private var device: CaptureDeviceInfo? {
        let id = CaptureFeed.resolve(id: cam.device, name: cam.deviceName, among: devices.map { ($0.id, $0.name) })
        return devices.first { $0.id == id }
    }

    /// "3840x2160", largest first, from what macOS says the device offers.
    private var sizes: [String] {
        let all = (device?.formats ?? []).compactMap { $0.components(separatedBy: " @ ").first }
        var seen = Set<String>(), out: [String] = []
        for s in all where seen.insert(s).inserted { out.append(s) }
        func area(_ s: String) -> Int { s.split(separator: "x").compactMap { Int($0) }.reduce(1, *) }
        return out.sorted { area($0) > area($1) }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: T.s3) {
            Text(label).font(.sans(12, .semibold)).foregroundStyle(T.inkMuted).frame(width: 130, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func note(_ s: String) -> some View { Text(s).font(.sans(12)).foregroundStyle(T.inkSubtle) }

    var body: some View {
        Card {
            // Header: on and off, name, remove.
            HStack(spacing: T.s3) {
                Toggle("", isOn: Binding(get: { cam.enabled }, set: { v in edit { $0.enabled = v } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help(cam.enabled ? "On: capturing and sending over NDI" : "Off: nothing is captured or sent")
                TextField("Name", text: $nameDraft).textFieldStyle(CueFieldStyle()).frame(width: 220).focused($focus, equals: .name)
                    .onSubmit { commitName() }
                Text(cam.enabled ? "On" : "Off").font(.sans(12, .semibold)).foregroundStyle(cam.enabled ? T.success : T.inkSubtle)
                Spacer(minLength: 0)
                IconButton(icon: "trash", help: "Remove \(cam.name)") { store.update { $0.virtualCameras.removeAll { $0.id == cam.id } } }
            }

            labeled("Capture device") {
                MenuField(text: device?.name ?? "Not found", width: 260) {
                    ForEach(devices, id: \.id) { d in Button(d.name) { edit { $0.device = d.id; $0.deviceName = d.name; $0.inputFormat = nil } } }
                }
                if device == nil { note("Plug it in, then Refresh devices.") }
            }

            labeled("Input quality") {
                Toggle("", isOn: Binding(
                    get: { cam.inputFormat == nil },
                    set: { auto in edit { $0.inputFormat = auto ? nil : (sizes.first ?? "1920x1080") } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                note(cam.inputFormat == nil ? "Automatic: the largest picture the device gives." : "Chosen by hand:")
                if cam.inputFormat != nil {
                    MenuField(text: cam.inputFormat ?? "", width: 140) {
                        ForEach(sizes, id: \.self) { s in Button(label(for: s)) { edit { $0.inputFormat = s } } }
                    }
                }
            }
            if !sizes.isEmpty, sizes.allSatisfy({ !$0.hasPrefix("3840") }) {
                labeled("") { note("This device gives no 4K over USB, only up to \(sizes.first ?? "1080p"). Zoom range will be small.") }
            }

            labeled("Output size") {
                Segments(items: [("1080p", OutputSize.p1080), ("720p", OutputSize.p720)],
                         selection: Binding(get: { cam.output }, set: { v in edit { $0.output = v } }))
                note("720p leaves more room to zoom from the same input.")
            }

            labeled("NDI name") {
                TextField("NDI name", text: $ndiDraft).textFieldStyle(CueFieldStyle()).frame(width: 220).focused($focus, equals: .ndi)
                    .onSubmit { commitNDI() }
                note("Seen in vMix and Zoom as \"\(Host.current().localizedName ?? "This Mac") (\(cam.ndiName))\".")
            }

            labeled("Follow shot") {
                Segments(items: ShotSize.allCases.map { ($0.short, $0.rawValue) },
                         selection: Binding(get: { cam.shotSize }, set: { v in edit { $0.shotSize = v } }))
                note("How tight it frames the person.")
            }

            labeled("Zoom limit") {
                Toggle("", isOn: Binding(
                    get: { cam.maxZoom == nil },
                    set: { auto in edit { $0.maxZoom = auto ? nil : zoomDraft } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                if cam.maxZoom == nil {
                    note("Automatic: worked out from the input and output sizes.")
                } else {
                    Slider(value: $zoomDraft, in: 1...4, step: 0.25) { editing in
                        if !editing { edit { $0.maxZoom = zoomDraft } }
                    }.frame(width: 180)
                    Text(String(format: "%.2f×", zoomDraft)).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.inkMuted)
                }
            }

            Rectangle().fill(T.line).frame(height: 1)
            if cam.enabled { LiveStatus(id: cam.id, ndiName: cam.ndiName) } else { note("Switched off.") }
        }
        .onAppear {
            nameDraft = cam.name; ndiDraft = cam.ndiName; zoomDraft = cam.maxZoom ?? 2.5
            // A camera saved before names were kept learns its device's name while the device is here.
            if cam.deviceName == nil, let d = device { edit { $0.deviceName = d.name } }
        }
        .onChange(of: cam.name) { _, v in if focus != .name { nameDraft = v } }
        .onChange(of: cam.ndiName) { _, v in if focus != .ndi { ndiDraft = v } }
        .onChange(of: focus) { old, _ in
            // Leaving a field saves it, so a typed name is never lost.
            if old == .name { commitName() }
            if old == .ndi { commitNDI() }
        }
    }

    private func label(for size: String) -> String {
        switch size {
        case "3840x2160": return "3840x2160 (4K)"
        case "1920x1080": return "1920x1080 (1080p)"
        case "1280x720": return "1280x720 (720p)"
        default: return size
        }
    }

    private func commitName() {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { nameDraft = cam.name } else if n != cam.name { edit { $0.name = n } }
    }

    /// The NDI name reopens the output, so it is saved on Return or when leaving the field, not on each key.
    private func commitNDI() {
        let n = ndiDraft.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { ndiDraft = cam.ndiName } else if n != cam.ndiName { edit { $0.ndiName = n } }
    }
}

/// What a running virtual camera is doing, refreshed every second, with the controls to steer it.
private struct LiveStatus: View {
    let id: UUID
    let ndiName: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: T.s2) {
                if let r = VirtualCameras.shared.runtime(for: id) {
                    let s = r.status()
                    row("Capture", ok: s.captureLive, text: s.captureLive ? "Receiving \(s.input)" : (s.problem ?? "Waiting for the picture"))
                    row("NDI output", ok: s.outputLive,
                        text: s.runtimeMissing ? "NDI isn't installed on this Mac. Install NDI Tools."
                              : (s.outputLive ? "Sending, \(s.sent) frames, \(s.dropped) dropped" : "Not sending"))
                    HStack(spacing: T.s2) {
                        Text("Steering").font(.sans(12, .semibold)).foregroundStyle(T.inkMuted).frame(width: 130, alignment: .leading)
                        steer("Follow", active: s.mode == "follow") { r.followPerson() }
                        steer("Wide", active: s.mode == "wide") { r.wide() }
                        steer("Hold", active: s.mode == "hold") { r.hold() }
                        Text(s.mode == "follow" ? followText(s.phase) : s.mode == "shot" ? "At a saved shot" : "").font(.sans(12)).foregroundStyle(T.inkSubtle)
                    }
                    if s.zoomLimited {
                        Text("Zoom limit reached: the picture can't get any tighter for this shot at this input size.")
                            .font(.sans(12, .semibold)).foregroundStyle(T.warning)
                    }
                    if let z = s.maxZoom {
                        Text(String(format: "Zoom range up to %.2f× of the full picture.", z)).font(.sans(12)).foregroundStyle(T.inkSubtle)
                    }
                } else {
                    Text("Starting…").font(.sans(12)).foregroundStyle(T.inkSubtle)
                }
            }
        }
    }

    private func followText(_ phase: String) -> String {
        switch phase {
        case "following": return "Following a person"
        case "searching": return "Looking for them"
        case "lost": return "Lost sight, showing the whole picture"
        default: return "Waiting for someone in the picture"
        }
    }

    private func row(_ title: String, ok: Bool, text: String) -> some View {
        HStack(spacing: T.s2) {
            Text(title).font(.sans(12, .semibold)).foregroundStyle(T.inkMuted).frame(width: 130, alignment: .leading)
            Circle().fill(ok ? T.success : T.lineStrong).frame(width: 8, height: 8)
            Text(text).font(.sans(12)).foregroundStyle(ok ? T.ink : T.inkMuted).lineLimit(2)
        }
    }

    private func steer(_ title: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(CueButton(kind: active ? .primary : .secondary))
    }
}
