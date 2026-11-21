import SwiftUI
import UniformTypeIdentifiers

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
                    Text(devices.isEmpty ? "No virtual cameras yet. Add one, then pick a capture device (plug in the capture box and press Refresh devices) or an NDI source."
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
                    .buttonStyle(CueButton(kind: .primary))
                Button { devices = CaptureFeed.devices() } label: { Label("Refresh devices", systemImage: "arrow.clockwise") }
                    .buttonStyle(CueButton())
                Text(tr("\(devices.count) capture device\(devices.count == 1 ? "" : "s") found", es: "\(devices.count) capturadora\(devices.count == 1 ? "" : "s") encontrada\(devices.count == 1 ? "" : "s")")).font(.sans(12)).foregroundStyle(T.inkSubtle)
            }
            Text(tr("Only external capture devices are offered: this Mac's own camera can't be sent out as an NDI source.", es: "Solo se ofrecen capturadoras externas: la cámara propia de esta Mac no puede salir como fuente NDI."))
                .font(.sans(12)).foregroundStyle(T.inkSubtle)
            if !store.config.virtualCameras.isEmpty {
                NetworkControlCard().frame(maxWidth: 760, alignment: .leading)
                VMixCard().frame(maxWidth: 760, alignment: .leading)
                LaunchAtLoginCard().frame(maxWidth: 760, alignment: .leading)
            }
        }
        .onAppear { devices = CaptureFeed.devices() }
    }

    /// With a capture device plugged in it starts on that; with none it starts on an NDI source to choose.
    private func add() {
        let n = store.config.virtualCameras.count + 1
        store.update {
            var cam = VirtualCamera(name: "Virtual camera \(n)", device: devices.first?.id ?? "", ndiName: "Virtual camera \(n)")
            cam.deviceName = devices.first?.name
            if devices.isEmpty { cam.ndiSource = "" }
            $0.virtualCameras.append(cam)
        }
    }
}

/// Where a virtual camera's picture comes from.
private enum InputKind: Hashable { case usb, ndi, file }

struct VirtualCameraCard: View {
    let cam: VirtualCamera
    let devices: [CaptureDeviceInfo]
    @EnvironmentObject var store: ConfigStore
    @State private var nameDraft = ""
    @State private var ndiDraft = ""
    @State private var groupDraft = ""
    @State private var zoomDraft = VirtualCamera.manualZoomDefault
    @FocusState private var focus: Field?
    private enum Field { case name, ndi, group }

    /// Changes this camera in the setup. Whether the running camera is reopened is decided by
    /// VirtualCameras.apply from `VirtualCamera.pipeline`: only the device, input size, output size,
    /// NDI name and zoom limit do; anything else (name, shot size, saved shots) leaves the picture running.
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
                    .help(cam.enabled ? tr("On: capturing and sending over NDI", es: "Encendida: captura y envía por NDI") : tr("Off: nothing is captured or sent", es: "Apagada: no se captura ni se envía nada"))
                TextField("Name", text: $nameDraft).textFieldStyle(CueFieldStyle()).frame(width: 220).focused($focus, equals: .name)
                    .onSubmit { commitName() }
                Text(cam.enabled ? "On" : "Off").font(.sans(12, .semibold)).foregroundStyle(cam.enabled ? T.success : T.inkSubtle)
                Spacer(minLength: 0)
                IconButton(icon: "trash", help: tr("Remove \(cam.name)", es: "Quitar \(cam.name)")) { store.update { $0.virtualCameras.removeAll { $0.id == cam.id } } }
            }

            // Where the picture comes from: a USB capture device, or an NDI source on the network
            // (the camera as vMix or a switcher sends it).
            labeled("Input") {
                Segments(items: [("USB capture", InputKind.usb), ("NDI source", InputKind.ndi), ("Video file", InputKind.file)],
                         selection: Binding(
                            get: { cam.videoFile != nil ? .file : (cam.ndiSource == nil ? .usb : .ndi) },
                            set: { kind in edit {
                                $0.ndiSource = kind == .ndi ? ($0.ndiSource ?? "") : nil
                                $0.videoFile = kind == .file ? ($0.videoFile ?? "") : nil
                                $0.inputFormat = nil
                            } }))
            }

            if cam.videoFile != nil {
                labeled("Video file") {
                    Button(cam.videoFile.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent } ?? "Choose a file…") { chooseFile() }
                        .buttonStyle(CueButton(kind: .secondary))
                }
                labeled("") { note(tr("A recorded clip plays in a loop as this camera's picture, to tune tracking without the camera.", es: "Un clip grabado se repite como imagen de esta cámara, para afinar el seguimiento sin la cámara.")) }
            } else if cam.ndiSource == nil {
                labeled("Capture device") {
                    MenuField(text: device?.name ?? "Not found", width: 260) {
                        ForEach(devices, id: \.id) { d in Button(d.name) { edit { $0.device = d.id; $0.deviceName = d.name; $0.inputFormat = nil } } }
                    }
                    if device == nil { note(tr("Plug it in, then Refresh devices.", es: "Conectala y después tocá Refresh devices.")) }
                }

                labeled("Input quality") {
                    Toggle("", isOn: Binding(
                        get: { cam.inputFormat == nil },
                        set: { auto in edit { $0.inputFormat = auto ? nil : (sizes.first ?? "1920x1080") } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    note(cam.inputFormat == nil ? tr("Automatic: the largest picture the device gives.", es: "Automático: la imagen más grande que da el dispositivo.") : tr("Chosen by hand:", es: "Elegida a mano:"))
                    if cam.inputFormat != nil {
                        MenuField(text: cam.inputFormat ?? "", width: 140) {
                            ForEach(sizes, id: \.self) { s in Button(label(for: s)) { edit { $0.inputFormat = s } } }
                        }
                    }
                }
                if !sizes.isEmpty, sizes.allSatisfy({ CaptureFeed.height(of: $0) < 2160 }) {
                    labeled("") { note(tr("This device gives no 4K over USB, only up to \(sizes.first ?? "1080p"). Zoom range will be small.", es: "Este dispositivo no da 4K por USB, solo hasta \(sizes.first ?? "1080p"). El rango de zoom será chico.")) }
                }
            } else {
                labeled("NDI source") {
                    NDIPicker(selection: cam.ndiSource.flatMap { $0.isEmpty ? nil : $0 }, none: "Choose a source") { v in
                        edit { $0.ndiSource = v ?? "" }
                    }
                    .frame(width: 260)
                }
                labeled("") {
                    note(cam.inputIsOwnOutput
                         ? tr("This is this camera's own output. Pick the one your switcher or vMix sends.",
                              es: "Esta es la salida de esta misma cámara. Elegí la que manda tu switcher o vMix.")
                         : tr("The full picture is taken over the network, so a wired connection works best. The zoom range follows what the sender gives.",
                              es: "La imagen completa llega por la red, así que conviene el cable. El rango de zoom depende de lo que mande el emisor."))
                        .foregroundStyle(cam.inputIsOwnOutput ? T.warning : T.inkSubtle)
                }
            }

            labeled("Output size") {
                Segments(items: [("1080p", OutputSize.p1080), ("720p", OutputSize.p720)],
                         selection: Binding(get: { cam.output }, set: { v in edit { $0.output = v } }))
                note(tr("720p leaves more room to zoom from the same input.", es: "720p deja más margen de zoom con la misma entrada."))
            }

            labeled("NDI group") {
                TextField("Public", text: $groupDraft).textFieldStyle(CueFieldStyle()).frame(width: 220).focused($focus, equals: .group)
                    .onSubmit { commitGroup() }
                note(tr("Empty: anyone on the network sees it. Set one or more groups (comma separated) so only receivers looking in them do. It filters, it doesn't lock.", es: "Vacío: lo ve cualquiera en la red. Poné uno o más grupos (separados por comas) para que solo lo vean los receptores que miran esos grupos. Filtra, no bloquea."))
            }

            labeled("Colour format") {
                Segments(items: [("BGRA", false), ("UYVY", true)],
                         selection: Binding(get: { cam.sendUYVY }, set: { v in edit { $0.sendUYVY = v } }))
                note(tr("UYVY sends half the data and is what most NDI receivers work in. Leave BGRA unless the network is the limit.", es: "UYVY envía la mitad de los datos y es lo que usan la mayoría de los receptores NDI. Dejá BGRA salvo que la red sea el límite."))
            }

            labeled("NDI name") {
                TextField("NDI name", text: $ndiDraft).textFieldStyle(CueFieldStyle()).frame(width: 220).focused($focus, equals: .ndi)
                    .onSubmit { commitNDI() }
                note(tr("Seen in vMix and Zoom as \"\(Host.current().localizedName ?? "This Mac") (\(cam.ndiName))\".", es: "Se ve en vMix y Zoom como \"\(Host.current().localizedName ?? "esta Mac") (\(cam.ndiName))\"."))
            }

            labeled("Saved shots") {
                if cam.shots.isEmpty {
                    note(tr("None yet. On Operate, frame the picture and press Save shot.", es: "Todavía no hay. En Operate, encuadrá la imagen y tocá Save shot."))
                } else {
                    VStack(alignment: .leading, spacing: T.s2) {
                        ForEach(cam.shots) { shot in
                            HStack(spacing: T.s2) {
                                ShotNameField(name: shot.name) { n in edit { c in
                                    if let i = c.shots.firstIndex(where: { $0.id == shot.id }) { c.shots[i].name = n }
                                } }
                                IconButton(icon: "trash", help: tr("Remove \(shot.name)", es: "Quitar \(shot.name)")) { edit { $0.shots.removeAll { $0.id == shot.id } } }
                            }
                        }
                    }
                }
            }

            labeled("Starts as") {
                Segments(items: [("Follow", StartMode.follow), ("Wide", StartMode.wide)]
                            + (cam.shots.isEmpty ? [] : [("Saved shot", StartMode.shot)]),
                         selection: Binding(get: { cam.startMode }, set: { v in
                    edit { $0.startMode = v; if v == .shot, $0.startShot == nil { $0.startShot = $0.shots.first?.id } }
                }))
                if cam.startMode == .shot, !cam.shots.isEmpty {
                    MenuField(text: cam.shots.first { $0.id == cam.startShot }?.name ?? "Pick a shot", width: 160) {
                        ForEach(cam.shots) { s in Button(s.name) { edit { $0.startShot = s.id } } }
                    }
                }
                note(cam.startMode == .wide ? tr("Opens on the whole picture and stays there: a fixed general shot.", es: "Abre en la imagen completa y se queda ahí: un plano general fijo.")
                                            : tr("How it starts when the app opens.", es: "Cómo arranca al abrir la app."))
            }

            labeled("Follow shot") {
                Segments(items: ShotSize.allCases.map { ($0.short, $0.rawValue) },
                         selection: Binding(get: { cam.shotSize }, set: { v in edit { $0.shotSize = v } }))
                note(tr("How tight it frames the person.", es: "Qué tan cerrado encuadra a la persona."))
            }

            labeled("Zoom limit") {
                Toggle("", isOn: Binding(
                    get: { cam.maxZoom == nil },
                    set: { auto in edit { $0.maxZoom = auto ? nil : zoomDraft } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                if cam.maxZoom == nil {
                    note(tr("Automatic: worked out from the input and output sizes.", es: "Automático: se calcula con los tamaños de entrada y de salida."))
                } else {
                    Slider(value: $zoomDraft, in: VirtualCamera.manualZoomRange, step: 0.25) { editing in
                        if !editing { edit { $0.maxZoom = zoomDraft } }
                    }.frame(width: 180)
                    Text(String(format: "%.2f×", zoomDraft)).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.inkMuted)
                }
            }

            Rectangle().fill(T.line).frame(height: 1)
            if cam.enabled { LiveStatus(id: cam.id, ndiName: cam.ndiName) } else { note(tr("Switched off.", es: "Apagada.")) }
        }
        .onAppear {
            nameDraft = cam.name; ndiDraft = cam.ndiName; groupDraft = cam.ndiGroups ?? ""; zoomDraft = cam.maxZoom ?? VirtualCamera.manualZoomDefault
            // A camera saved before names were kept learns its device's name while the device is here.
            if cam.deviceName == nil, let d = device { edit { $0.deviceName = d.name } }
        }
        .onChange(of: cam.name) { _, v in if focus != .name { nameDraft = v } }
        .onChange(of: cam.ndiName) { _, v in if focus != .ndi { ndiDraft = v } }
        .onChange(of: cam.ndiGroups) { _, v in if focus != .group { groupDraft = v ?? "" } }
        .onChange(of: focus) { old, _ in
            // Leaving a field saves it, so a typed name is never lost.
            if old == .name { commitName() }
            if old == .ndi { commitNDI() }
            if old == .group { commitGroup() }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.canChooseDirectories = false
        panel.message = "Choose a recorded clip to play in a loop as this camera's picture"
        if panel.runModal() == .OK, let url = panel.url { edit { $0.videoFile = url.path } }
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
    /// Reopens the NDI output (the group is part of how the source is announced), so it is saved on Return or when leaving the field.
    private func commitGroup() {
        let g = VirtualCamera.cleanGroups(groupDraft)
        groupDraft = g ?? ""
        if g != cam.ndiGroups { edit { $0.ndiGroups = g } }
    }

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
                    row("Capture", ok: s.captureLive, text: s.captureLive ? tr("Receiving \(s.input)", es: "Recibiendo \(s.input)") : (s.problem ?? tr("Waiting for the picture", es: "Esperando la imagen")))
                    row("NDI output", ok: s.outputLive,
                        text: s.runtimeMissing ? tr("NDI isn't installed on this Mac. Install NDI Tools.", es: "NDI no está instalado en esta Mac. Instalá NDI Tools.")
                              : (s.outputLive ? tr("Sending as \"\(ndiName)\", \(s.sent) frames, \(s.dropped) dropped", es: "Enviando como \"\(ndiName)\", \(s.sent) cuadros, \(s.dropped) perdidos") : tr("Not sending", es: "Sin enviar")))
                    HStack(spacing: T.s2) {
                        Text("Steering").font(.sans(12, .semibold)).foregroundStyle(T.inkMuted).frame(width: 130, alignment: .leading)
                        steer("Follow", active: s.mode == "follow") { r.followPerson() }
                        steer("Wide", active: s.mode == "wide") { r.wide() }
                        steer("Hold", active: s.mode == "hold") { r.hold() }
                        Text(s.mode == "follow" || s.mode == "shot" ? s.steeringText : "").font(.sans(12)).foregroundStyle(T.inkSubtle)
                    }
                    if s.zoomLimited {
                        Text(tr("Zoom limit reached: the picture can't get any tighter for this shot at this input size.", es: "Se llegó al límite de zoom: la imagen no puede cerrarse más para este plano con este tamaño de entrada."))
                            .font(.sans(12, .semibold)).foregroundStyle(T.warning)
                    }
                    if let z = s.maxZoom {
                        Text(tr(String(format: "Zoom range up to %.2f× of the full picture.", z), es: String(format: "Rango de zoom hasta %.2f× de la imagen completa.", z))).font(.sans(12)).foregroundStyle(T.inkSubtle)
                    }
                } else {
                    Text(tr("Starting…", es: "Iniciando…")).font(.sans(12)).foregroundStyle(T.inkSubtle)
                }
            }
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

/// One saved shot's name: typed freely and saved on Return or when leaving the field.
private struct ShotNameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Shot name", text: $draft).textFieldStyle(CueFieldStyle()).frame(width: 200).focused($focused)
            .onSubmit { save() }
            .onAppear { draft = name }
            .onChange(of: name) { _, v in if !focused { draft = v } }
            .onChange(of: focused) { _, now in if !now { save() } }
    }

    private func save() {
        let n = draft.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { draft = name } else if n != name { commit(n) }
    }
}

/// Switch for steering the virtual cameras from other computers (vMix, Stream Deck), with the
/// address to use and the key it needs.
private struct NetworkControlCard: View {
    @EnvironmentObject var store: ConfigStore
    @State private var copied = false

    private var host: String { (Host.current().localizedName ?? "this-mac").replacingOccurrences(of: " ", with: "-") + ".local" }

    var body: some View {
        Card(title: "Network control") {
            VStack(alignment: .leading, spacing: T.s3) {
                HStack(spacing: T.s3) {
                    Toggle("", isOn: Binding(get: { store.config.networkControl },
                                             set: { on in store.update { $0.networkControl = on } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    Text(store.config.networkControl ? tr("On: other computers can steer the virtual cameras", es: "Encendido: otras computadoras pueden mover las cámaras virtuales") : tr("Off", es: "Apagado"))
                        .font(.sans(13)).foregroundStyle(store.config.networkControl ? T.ink : T.inkSubtle)
                }
                if store.config.networkControl {
                    Text("http://\(host):\(NetworkControl.defaultPort)/camera/<camera name>/follow?key=<key>")
                        .font(.sans(12)).textSelection(.enabled).foregroundStyle(T.inkMuted)
                    Text(tr("Also: wide, hold, follow/full, shot/<saved shot>, zoom/in, zoom/out, and /cameras for the list. It only steers; it can't change the setup.", es: "También: wide, hold, follow/full, shot/<toma guardada>, zoom/in, zoom/out, y /cameras para la lista. Solo mueve cámaras; no puede cambiar la configuración."))
                        .font(.sans(12)).foregroundStyle(T.inkSubtle)
                    HStack(spacing: T.s2) {
                        Button(copied ? "Copied" : "Copy key") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(NetworkControl.loadOrMakeKey(), forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        }.buttonStyle(CueButton())
                        Button("New key") { NetworkControl.shared.renewKey(); copied = false }
                            .buttonStyle(CueButton())
                            .help(tr("Replaces the key: anything using the old one stops working", es: "Cambia la clave: lo que use la anterior deja de funcionar"))
                    }
                    Text(tr("Not encrypted: use it on a closed network, like a switch only the streaming computers are on.", es: "No va cifrado: usalo en una red cerrada, como un switch donde solo estén las computadoras de la transmisión."))
                        .font(.sans(12)).foregroundStyle(T.warning)
                } else {
                    Text(tr("Off by default. Switch it on to let vMix, Companion or a Stream Deck send simple web requests that steer a camera.", es: "Apagado por defecto. Encendelo para que vMix, Companion o un Stream Deck muevan una cámara con pedidos web simples."))
                        .font(.sans(12)).foregroundStyle(T.inkSubtle)
                }
            }
        }
    }
}

/// Start with the Mac, and come back after a crash: for the Mac that runs the cameras unattended.
private struct LaunchAtLoginCard: View {
    @State private var state = LaunchAtLogin.current
    @State private var error: String?

    var body: some View {
        Card(title: "Start with this Mac") {
            VStack(alignment: .leading, spacing: T.s3) {
                HStack(spacing: T.s3) {
                    Toggle("", isOn: Binding(get: { state == .on || state == .needsApproval }, set: { change($0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(state == .unavailable)
                    Text(label).font(.sans(13)).foregroundStyle(state == .off || state == .unavailable ? T.inkSubtle : T.ink)
                }
                if state == .needsApproval {
                    Button("Open Login Items") { LaunchAtLogin.openLoginItems() }.buttonStyle(CueButton())
                }
                if let error { Text(error).font(.sans(12)).foregroundStyle(T.danger) }
                Text(tr("Opens the app when you log in, and again if it crashes. Quitting it yourself keeps it quit. If macOS started this copy, switching this off may close it. Set the Mac to log in by itself (Users & Groups) for a start with no one there.", es: "Abre la app al iniciar sesión, y de nuevo si se cierra por un error. Si la cerrás vos, queda cerrada. Si macOS abrió esta copia, apagar esto puede cerrarla. Para que arranque sin nadie, poné la Mac en inicio de sesión automático (Usuarios y grupos)."))
                    .font(.sans(12)).foregroundStyle(T.inkSubtle)
            }
        }
        .onAppear { state = LaunchAtLogin.current }
    }

    private var label: String {
        switch state {
        case .on: return tr("On: starts at login and after a crash", es: "Encendido: arranca al iniciar sesión y tras un error")
        case .off: return tr("Off", es: "Apagado")
        case .needsApproval: return tr("Allow Churchfront Video in System Settings > Login Items to finish", es: "Permití Churchfront Video en Ajustes del Sistema > Ítems de inicio para terminar")
        case .unavailable: return tr("Only in the built app (Churchfront Video.app)", es: "Solo en la app compilada (Churchfront Video.app)")
        }
    }

    private func change(_ on: Bool) {
        do { try LaunchAtLogin.set(on); error = nil } catch { self.error = tr("Couldn't change it: \(error.localizedDescription)", es: "No se pudo cambiar: \(error.localizedDescription)") }
        state = LaunchAtLogin.current
    }
}

/// Reads what is on air from the vMix machine, to show ON AIR / NEXT on each camera and, if asked, rest the others.
private struct VMixCard: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var vmix = VMixLink.shared
    @State private var host = ""
    @FocusState private var focused: Bool

    private var settings: VMixSettings { store.config.vmix }

    var body: some View {
        Card(title: "vMix") {
            VStack(alignment: .leading, spacing: T.s3) {
                HStack(spacing: T.s3) {
                    Toggle("", isOn: Binding(get: { settings.enabled }, set: { on in store.update { $0.vmix.enabled = on } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    TextField("vMix PC address", text: $host).textFieldStyle(CueFieldStyle()).frame(width: 220).focused($focused)
                        .onSubmit { commit() }
                    Text(status).font(.sans(12)).foregroundStyle(vmix.reachable ? T.success : T.inkSubtle)
                }
                if settings.enabled {
                    HStack(spacing: T.s3) {
                        Toggle("", isOn: Binding(get: { settings.wideWhenOffAir }, set: { on in store.update { $0.vmix.wideWhenOffAir = on } }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        Text(tr("Rest at the whole picture when vMix isn't using the camera", es: "Quedar en la imagen completa cuando vMix no usa la cámara"))
                            .font(.sans(12)).foregroundStyle(T.inkMuted)
                    }
                }
                Text(tr("Reads which input is on air from vMix's web controller (Settings > Web Controller, port 8088), twice a second, and matches each camera by its NDI name. It only reads: it never sends anything to vMix. If vMix stops answering, cameras go back to following.",
                        es: "Lee qué entrada está al aire desde la Web Controller de vMix (Settings > Web Controller, puerto 8088), dos veces por segundo, y empareja cada cámara por su nombre NDI. Solo lee: nunca le manda nada a vMix. Si vMix deja de responder, las cámaras vuelven a seguir."))
                    .font(.sans(12)).foregroundStyle(T.inkSubtle)
            }
        }
        .onAppear { host = settings.host }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private var status: String {
        guard settings.enabled else { return tr("Off", es: "Apagado") }
        guard !settings.host.isEmpty else { return tr("Enter the address", es: "Poné la dirección") }
        if vmix.reachable { return tr("Connected, \(vmix.state?.inputs.count ?? 0) inputs", es: "Conectado, \(vmix.state?.inputs.count ?? 0) entradas") }
        return tr("Can't reach vMix", es: "No se puede alcanzar vMix")
    }

    private func commit() {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h != settings.host { store.update { $0.vmix.host = h } }
    }
}
