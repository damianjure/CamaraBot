import Foundation
import Combine

/// vMix's own picture of what is on air, from its web API (`http://<pc>:8088/api`, the XML state).
struct VMixState: Equatable {
    struct Input: Equatable { var number: Int; var title: String }
    var inputs: [Input] = []
    /// Input numbers, counted from 1 as vMix does.
    var active: Int?
    var preview: Int?

    enum Tally: Equatable { case program, preview, off }

    /// Where the input named like this is: on air, next, or neither. An input is the camera's when
    /// its title carries the camera's NDI name (vMix names an NDI input "COMPUTER (name)").
    /// Nil when vMix has no such input at all.
    func tally(ndiName: String) -> Tally? {
        let q = ndiName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let mine = inputs.filter { $0.title.lowercased().contains(q) }
        guard !mine.isEmpty else { return nil }
        if mine.contains(where: { $0.number == active }) { return .program }
        if mine.contains(where: { $0.number == preview }) { return .preview }
        return .off
    }

    /// The state from vMix's XML, or nil when it isn't vMix's state.
    static func parse(_ data: Data) -> VMixState? {
        let p = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        guard xml.parse(), p.sawRoot else { return nil }
        return VMixState(inputs: p.inputs, active: p.active, preview: p.preview)
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var inputs: [Input] = []
        var active: Int?, preview: Int?
        var sawRoot = false
        private var number: Int?, attrTitle = "", text = "", element = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if name == "vmix" { sawRoot = true }
            element = name
            text = ""
            if name == "input" { number = Int(a["number"] ?? ""); attrTitle = a["title"] ?? "" }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "input":
                // The element's own text is the title as shown; the attribute is the same, or the fallback.
                if let n = number { inputs.append(Input(number: n, title: attrTitle.isEmpty ? t : attrTitle)) }
                number = nil
            case "active": active = Int(t)
            case "preview": preview = Int(t)
            default: break
            }
            text = ""
        }
    }
}

/// Settings for reading a vMix machine, in the setup file under "vmix".
struct VMixSettings: Codable, Equatable {
    var enabled = false
    var host = ""
    var port = 8088
    /// A camera that is neither on air nor next goes to the whole picture, and comes back when it is needed.
    var wideWhenOffAir = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = (try c.decodeIfPresent(String.self, forKey: .host) ?? "").trimmingCharacters(in: .whitespaces)
        let p = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8088
        port = (1...65535).contains(p) ? p : 8088
        wideWhenOffAir = try c.decodeIfPresent(Bool.self, forKey: .wideWhenOffAir) ?? false
    }
    private enum Keys: String, CodingKey { case enabled, host, port, wideWhenOffAir }

    var url: URL? {
        guard enabled, !host.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "http"; c.host = host; c.port = port; c.path = "/api"
        return c.url
    }
}

/// Asks vMix what is on air twice a second and keeps the answer, so the operator tile can show it
/// and, if asked to, cameras that aren't needed rest at the whole picture. It only ever reads from
/// vMix. When vMix stops answering, anything it did to a camera is undone.
final class VMixLink: ObservableObject {
    static let shared = VMixLink()
    /// The running virtual cameras (replaced in tests).
    var cameras: () -> [VirtualCameraRuntime] = { VirtualCameras.shared.all }
    static let interval = 0.5
    /// Answers missed in a row before vMix counts as gone.
    static let misses = 4

    @Published private(set) var state: VMixState?
    @Published private(set) var reachable = false
    private var missed = 0
    private var settings = VMixSettings()
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        return URLSession(configuration: c)
    }()
    /// Cameras this link put at the whole picture. Only cameras that were following are ever rested, so following is what they go back to.
    private var resting = Set<UUID>()

    func attach(_ store: ConfigStore) {
        subscription = store.$config.map(\.vmix).removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.apply(s) }
    }

    func apply(_ s: VMixSettings) {
        settings = s
        timer?.invalidate(); timer = nil
        guard s.url != nil else { clear(); return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// For a camera by its NDI name; nil while vMix isn't answering or has no such input.
    func tally(ndiName: String) -> VMixState.Tally? {
        guard reachable else { return nil }
        return state?.tally(ndiName: ndiName)
    }

    private func poll() {
        guard let url = settings.url else { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            let parsed = data.flatMap(VMixState.parse)
            DispatchQueue.main.async { self?.got(parsed) }
        }.resume()
    }

    func got(_ parsed: VMixState?) {
        guard settings.url != nil else { return }
        if let parsed {
            missed = 0
            state = parsed
            reachable = true
            restOrWake(parsed)
        } else {
            missed += 1
            if missed >= Self.misses { clear() }
        }
    }

    /// vMix is gone (or switched off here): cameras it rested are given back.
    private func clear() {
        missed = 0
        reachable = false
        state = nil
        wakeAll()
    }

    private func restOrWake(_ s: VMixState) {
        guard settings.wideWhenOffAir else { wakeAll(); return }
        for r in cameras() {
            let id = r.camera.id
            switch s.tally(ndiName: r.camera.ndiName) {
            case .off?:
                // Only a camera still doing what the setup started it with is put to rest: one the operator is steering stays as it is.
                if !resting.contains(id), r.currentMode == .follow { resting.insert(id); r.wide() }
            case .program?, .preview?, nil:
                if resting.remove(id) != nil, r.currentMode == .wide { r.followPerson() }
            }
        }
    }

    private func wakeAll() {
        let all = cameras()
        for r in all {
            if resting.remove(r.camera.id) != nil, r.currentMode == .wide { r.followPerson() }
        }
        resting = resting.filter { id in all.contains { $0.camera.id == id } }
    }
}
