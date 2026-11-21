import SwiftUI
import CueATEM

/// What the main window shows: Operate, the booth volunteer's screen (Next and Live on top,
/// shots, camera control and the take buttons below), or one of the other pages. Cut, fade
/// and the camera keys only work on Operate.
enum AppView: String {
    case operate, engineer
}

/// The pages after Operate, as tabs in the top bar.
enum EngineerSection: String, CaseIterable, Identifiable {
    case scan, routing, switcher, setup, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "Stage scan"
        case .routing: return "Routing"
        case .switcher: return "Full switcher"
        case .setup: return "Setup"
        case .status: return "Status"
        }
    }
    var note: String {
        switch self {
        case .scan: return tr("People, labels, shots", es: "Personas, etiquetas, tomas")
        case .routing: return tr("Screens and buttons", es: "Pantallas y botones")
        case .switcher: return tr("Keys, T-bar, macros, aux", es: "Keys, T-bar, macros, aux")
        case .setup: return tr("Sources, keys, cameras", es: "Fuentes, keys, cámaras")
        case .status: return tr("Connections and log", es: "Conexiones y registro")
        }
    }
    var icon: String {
        switch self {
        case .scan: return "person.2.crop.square.stack"
        case .routing: return "arrow.triangle.branch"
        case .switcher: return "square.grid.3x2"
        case .setup: return "gearshape"
        case .status: return "waveform.path.ecg"
        }
    }
}

/// A page other than Operate: stage scan, routing, the full switcher, setup or status.
/// The tabs that choose it, and what's on air, are in the bar across the top of the window.
struct EngineerView: View {
    @EnvironmentObject var booth: Booth

    var body: some View {
        page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(T.bg)
    }

    @ViewBuilder private var page: some View {
        switch booth.section {
        case .scan: StageScanWindow()
        case .routing: RoutingWindow()
        case .switcher: SwitcherWindow()
        case .setup: SetupTab()
        case .status: StatusTab()
        }
    }
}
