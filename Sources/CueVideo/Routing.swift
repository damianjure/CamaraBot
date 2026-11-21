import SwiftUI
import CueATEM

// Video routing: which picture goes to which screen.
//
// The switcher's aux outputs feed the screens and encoders around the building. CueVideo
// names them (config "screens"), says what each M/E is for (config "mixNames": M/E 1 the
// live stream, M/E 2 the side screens), and gives volunteers a few routing buttons
// (config "routes") that work like macros: one press sends one or more screens a new
// picture, and a button is lit while the switcher already matches it.

/// Volunteer routing buttons, bottom right of the main window, with what each screen shows.
struct RoutePanel: View {
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let s = atem.state
        let routes = store.config.routes
        VStack(alignment: .leading, spacing: T.s2) {
            HStack {
                Text("Screens").panelLabel()
                Spacer()
                Button { Booth.shared.show(.routing) } label: { Image(systemName: "arrow.triangle.branch").font(.system(size: 11)) }
                    .buttonStyle(.borderless).foregroundStyle(T.inkSubtle).help(tr("Open the Routing page", es: "Abrir la página Routing"))
            }
            if !routes.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: T.s2), GridItem(.flexible(), spacing: T.s2)], spacing: T.s2) {
                    ForEach(routes) { r in RouteButtonView(route: r) }
                }
            }
            // What every volunteer-facing screen shows right now.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(store.config.screens.filter(\.forVolunteers)) { sc in
                    HStack(spacing: 6) {
                        Text(sc.name).font(.sans(11, .semibold)).foregroundStyle(T.inkMuted).lineLimit(1)
                        Image(systemName: "arrow.left").font(.system(size: 8, weight: .bold)).foregroundStyle(T.inkSubtle)
                        Text(RoutingText.showing(sc, s, store)).font(.sans(11)).foregroundStyle(T.ink).lineLimit(1)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

struct RouteButtonView: View {
    let route: RouteButton
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        let on = route.isActive(atem.state)
        Button { route.run(atem) } label: {
            VStack(spacing: 1) {
                Text(route.label).font(.sans(12, .semibold)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                Text(on ? "ON" : RoutingText.summary(route, store, atem.state)).font(.sans(9, .bold)).tracking(0.5)
                    .lineLimit(1).minimumScaleFactor(0.7).opacity(0.75)
            }
            .foregroundStyle(on ? T.onAction : T.ink)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: T.rMD).fill(on ? T.accent : T.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(on ? T.accent : T.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(RoutingText.detail(route, store, atem.state))
    }
}

enum RoutingText {
    /// What a screen shows: one source, or "mixed" when its linked auxes disagree.
    static func showing(_ sc: ScreenOutput, _ s: ATEMState, _ store: ConfigStore) -> String {
        let now = Set(sc.aux.map { s.aux[$0 - 1] })
        guard now.count == 1, let one = now.first else { return "Mixed" }
        return store.routeLabel(one, s)
    }

    /// Screen names a button changes: "LED wall, Lobby TVs".
    static func summary(_ r: RouteButton, _ store: ConfigStore, _ s: ATEMState) -> String {
        var names: [String] = []
        for c in r.set {
            let n = store.screen(aux: c.aux)?.name ?? "Aux \(c.aux)"
            if !names.contains(n) { names.append(n) }
        }
        return names.joined(separator: ", ").uppercased()
    }

    static func detail(_ r: RouteButton, _ store: ConfigStore, _ s: ATEMState) -> String {
        var lines: [String] = [], seen = Set<String>()
        for c in r.set {
            let n = store.screen(aux: c.aux)?.name ?? "Aux \(c.aux)"
            let line = "\(n) ← \(store.routeLabel(c.source, s))"
            if seen.insert(line).inserted { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Routing page

/// The whole picture for the system owner: what each mix is for, what every screen shows
/// and where it's wired, and the operator's routing buttons. Screens the operator cares
/// about come first; encoders, recorders and patch bay feeds fold away below them.
struct RoutingWindow: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore
    @State private var newButton = false

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: T.s3, alignment: .top)]

    var body: some View {
        Page(wide: true) {
            // No page title: the Routing tab above already says where this is.
            if atem.state.aux.isEmpty {
                Text("The switcher hasn't reported its outputs yet.").font(.sans(13)).foregroundStyle(T.inkMuted)
            } else {
                RoutingSchematic()
            }
            buttons
        }
    }

    // MARK: Buttons

    var buttons: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            HStack(spacing: T.s2) {
                Text("Operator routing buttons").panelLabel()
                HelpButton(text: tr("Buttons in the bottom right of Operate. Each one sends one or more screens a picture, like a macro, and lights up while the screens match it. The easy way to make one: route the screens the way you want above, then save that as a button.", es: "Botones abajo a la derecha de Operate. Cada uno manda una imagen a una o más pantallas, como un macro, y se enciende mientras las pantallas coinciden. La forma fácil de crear uno: enrutá las pantallas como quieras arriba y guardalo como botón."))
                Spacer()
                Button("Save the current routing as a button…") { newButton = true }
                    .buttonStyle(CueButton())
                    .popover(isPresented: $newButton) { NewRouteButton(done: { newButton = false }) }
            }
            if store.config.routes.isEmpty {
                Text("No buttons yet.").font(.sans(13)).foregroundStyle(T.inkMuted)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: T.s3) {
                ForEach(Array(store.config.routes.enumerated()), id: \.element.id) { i, r in routeCard(i, r) }
            }
        }
    }

    private func routeCard(_ i: Int, _ r: RouteButton) -> some View {
        let on = r.isActive(atem.state)
        return VStack(alignment: .leading, spacing: T.s2) {
            HStack(spacing: T.s2) {
                TextField("Label", text: Binding(get: { r.label }, set: { v in store.update { c in
                    if let j = c.routes.firstIndex(of: r), !v.isEmpty { c.routes[j].label = v }
                } }))
                .textFieldStyle(CueFieldStyle())
                if on { Tag(text: "On", color: T.accent, ink: T.onAction) }
            }
            Text(RoutingText.detail(r, store, atem.state)).font(.sans(11)).foregroundStyle(T.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 2) {
                Button("Run now") { r.run(atem) }.buttonStyle(CueButton())
                Spacer()
                IconButton(icon: "chevron.left", help: tr("Move earlier", es: "Mover antes")) { moveRoute(i, -1) }.disabled(i == 0)
                IconButton(icon: "chevron.right", help: tr("Move later", es: "Mover después")) { moveRoute(i, 1) }.disabled(i == store.config.routes.count - 1)
                IconButton(icon: "trash", help: tr("Remove this button", es: "Quitar este botón")) { store.update { $0.routes.removeAll { $0 == r } } }
            }
        }
        .padding(T.s3)
        .background(RoundedRectangle(cornerRadius: T.rLG).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: T.rLG).stroke(on ? T.accent : T.line))
    }

    func moveRoute(_ i: Int, _ d: Int) {
        store.update { c in
            let j = i + d
            guard c.routes.indices.contains(i), c.routes.indices.contains(j) else { return }
            c.routes.swapAt(i, j)
        }
    }
}

/// The pencil on a destination: opens its name, which outputs feed it, and its wiring note.
struct ScreenEditButton: View {
    let screen: ScreenOutput
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore
    @State private var editing = false
    @State private var name = ""
    @State private var auxText = ""
    @State private var note = ""

    /// Already in the setup file, rather than an output nobody has named.
    var named: Bool { store.config.screens.contains(screen) }
    var auxLabel: String { screen.aux.count == 1 ? "Aux \(screen.aux[0])" : "Aux " + screen.aux.map(String.init).joined(separator: ", ") }

    var body: some View {
        IconButton(icon: "pencil", help: named ? tr("Change the name, outputs or wiring note", es: "Cambiar el nombre, las salidas o la nota de cableado") : tr("Name this output", es: "Ponerle nombre a esta salida"), size: 15) { load(); editing = true }
            .popover(isPresented: $editing, arrowEdge: .trailing) { editor }
    }

    var editor: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(named ? "Edit \(screen.name)" : "Name \(auxLabel)").font(.sans(14, .bold))
            field("Name") { TextField("Such as Lobby TVs", text: $name).textFieldStyle(CueFieldStyle()).onSubmit(save) }
            field("Aux outputs") {
                TextField("4, 5", text: $auxText).textFieldStyle(CueFieldStyle()).onSubmit(save)
                Text(tr("Counted from 1. Several, such as 4, 5, switch together.", es: "Se cuentan desde 1. Varias, como 4, 5, cambian juntas.")).font(.sans(11)).foregroundStyle(T.inkSubtle)
            }
            field("Wiring note") { TextField("Such as Converter 1 → Lobby TV", text: $note).textFieldStyle(CueFieldStyle()).onSubmit(save) }
            if named {
                Toggle("Preview in the top bar", isOn: Binding(get: { store.pinnedScreens.contains { $0.id == screen.id } },
                                                               set: { store.setPinned(screen.id, $0) }))
                    .toggleStyle(.switch).controlSize(.small).font(.sans(12))
                    .help(tr("A small live picture of what this is showing, in the bar across the top. Up to four.", es: "Una imagen en vivo chica de lo que muestra esto, en la barra de arriba. Hasta cuatro."))
                Toggle("Show to operators", isOn: Binding(get: { screen.forVolunteers }, set: { v in update { $0.volunteer = v } }))
                    .toggleStyle(.switch).controlSize(.small).font(.sans(12))
                    .help(tr("Off for encoders, recorders and patch bay feeds: they move to Encoders and feeds, and Claude needs to be told to change them.", es: "Apagado para encoders, grabadores y salidas al patch bay: pasan a Encoders and feeds, y hay que pedirle a Claude que los cambie."))
            }
            HStack(spacing: T.s2) {
                if named {
                    Button("Forget this name") { store.update { $0.screens.removeAll { $0 == screen } }; editing = false }
                        .buttonStyle(CueButton(kind: .danger)).help(tr("The output stays; it goes back to Outputs not named yet.", es: "La salida queda; vuelve a Outputs not named yet."))
                }
                Spacer()
                Button("Cancel") { editing = false }.buttonStyle(CueButton())
                Button("Save") { save(); editing = false }.buttonStyle(CueButton(kind: .primary))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(T.s4)
        .frame(width: 340)
        .foregroundStyle(T.ink)
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.sans(11, .semibold)).foregroundStyle(T.inkMuted)
            content()
        }
    }

    func load() {
        name = named ? screen.name : ""
        auxText = screen.aux.map(String.init).joined(separator: ", ")
        note = screen.note ?? ""
    }

    func save() {
        let auxes = auxText.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { $0 >= 1 }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !auxes.isEmpty else { return }
        store.update { c in
            let new = ScreenOutput(name: n, aux: auxes, note: note.isEmpty ? nil : note, volunteer: screen.volunteer, pinned: screen.pinned)
            // An aux belongs to one screen: take these auxes away from any other.
            for i in c.screens.indices where c.screens[i] != screen { c.screens[i].aux.removeAll { auxes.contains($0) } }
            c.screens.removeAll { $0.aux.isEmpty }
            if let i = c.screens.firstIndex(of: screen) { c.screens[i] = new } else { c.screens.append(new) }
        }
    }

    func update(_ f: (inout ScreenOutput) -> Void) {
        store.update { c in if let i = c.screens.firstIndex(of: screen) { f(&c.screens[i]) } }
    }
}

/// Saves what chosen screens show now as an operator button.
struct NewRouteButton: View {
    let done: () -> Void
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var store: ConfigStore
    @State private var label = ""
    @State private var picked: Set<String> = []

    var body: some View {
        let s = atem.state
        VStack(alignment: .leading, spacing: T.s3) {
            Text("New routing button").font(.sans(14, .bold))
            TextField("Label, such as Lobby: stream", text: $label).textFieldStyle(CueFieldStyle()).frame(width: 320)
            Text("Screens it sets, to what they show now").font(.sans(12)).foregroundStyle(T.inkMuted)
            ForEach(store.config.screens) { sc in
                Toggle(isOn: Binding(get: { picked.contains(sc.id) }, set: { v in if v { picked.insert(sc.id) } else { picked.remove(sc.id) } })) {
                    Text("\(sc.name) ← \(RoutingText.showing(sc, s, store))").font(.sans(12))
                }
                .toggleStyle(.checkbox)
            }
            if store.config.screens.isEmpty {
                Text("Name the screens first.").font(.sans(12)).foregroundStyle(T.warning)
            }
            HStack(spacing: T.s2) {
                Spacer()
                Button("Cancel", action: done).buttonStyle(CueButton())
                Button("Save button") {
                    let set = store.config.screens.filter { picked.contains($0.id) }.flatMap { sc in
                        sc.aux.compactMap { a in s.aux[a - 1].map { RouteChange(aux: a, source: $0) } }
                    }
                    let l = label.trimmingCharacters(in: .whitespaces)
                    store.update { c in c.routes.removeAll { $0.label == l }; c.routes.append(RouteButton(label: l, set: set)) }
                    done()
                }
                .buttonStyle(CueButton(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty)
            }
        }
        .padding(T.s4)
        .foregroundStyle(T.ink)
    }
}
