import Foundation
import Network
import Combine

/// What a request to the network control asks for.
enum NetworkAction: Equatable {
    case list
    case follow(camera: String, size: String?)
    case wide(camera: String)
    case hold(camera: String)
    case shot(camera: String, name: String)
    case zoom(camera: String, closer: Bool)

    /// The action a path asks for, or nil when it isn't one:
    ///
    ///     /cameras
    ///     /camera/<name>/follow            /camera/<name>/follow/<shoulders|waist|full>
    ///     /camera/<name>/wide              /camera/<name>/hold
    ///     /camera/<name>/shot/<saved shot> /camera/<name>/zoom/<in|out>
    ///
    /// Names are percent-decoded, so "Main%20stage" is "Main stage".
    static func route(_ path: String) -> NetworkAction? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
        if parts == ["cameras"] { return .list }
        guard parts.count >= 3, parts[0] == "camera" else { return nil }
        let camera = parts[1]
        switch (parts[2].lowercased(), parts.count) {
        case ("follow", 3): return .follow(camera: camera, size: nil)
        case ("follow", 4): return .follow(camera: camera, size: parts[3])
        case ("wide", 3): return .wide(camera: camera)
        case ("hold", 3): return .hold(camera: camera)
        case ("shot", 4): return .shot(camera: camera, name: parts[3])
        case ("zoom", 4):
            switch parts[3].lowercased() {
            case "in": return .zoom(camera: camera, closer: true)
            case "out": return .zoom(camera: camera, closer: false)
            default: return nil
            }
        default: return nil
        }
    }
}

/// Steers the virtual cameras from other computers on the network, with plain web requests that
/// vMix, Bitfocus Companion or a Stream Deck can send:
///
///     http://<this Mac>:9912/camera/Pulpit/follow?key=<the key>
///
/// Off unless switched on in Setup. It can only steer (follow, wide, hold, saved shots, zoom):
/// it can't change the setup, and it has its own key, apart from the one Claude's link uses. The
/// key goes in the `key` part of the address or the `x-cuevideo-key` header. It is meant for a
/// closed network, such as a switch only the streaming computers are on: the traffic isn't encrypted.
final class NetworkControl {
    static let shared = NetworkControl()
    static let defaultPort: UInt16 = 9912

    let port: UInt16
    private let find: (String?) -> VirtualCameraRuntime?
    private var config: () -> CueConfig
    /// A key given up front (tests), instead of the one kept in the support folder.
    private let fixedKey: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cuevideo.network-control")
    private var subscription: AnyCancellable?
    private(set) var key = ""
    private(set) var running = false

    init(port: UInt16 = NetworkControl.defaultPort,
         find: @escaping (String?) -> VirtualCameraRuntime? = { VirtualCameras.shared.find($0) },
         config: @escaping () -> CueConfig = { CueConfig() },
         key: String? = nil) {
        self.port = port
        self.fixedKey = key
        self.find = find
        self.config = config
    }

    static var keyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueVideo", isDirectory: true).appendingPathComponent("network-key")
    }

    /// Follows the setup's switch: listening while it is on, closed while it is off.
    func attach(_ store: ConfigStore) {
        subscription = store.$config.map(\.networkControl).removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                guard let self else { return }
                self.config = { store.config }
                if on { self.start() } else { self.stop() }
            }
    }

    func start() {
        guard listener == nil else { return }
        key = fixedKey ?? Self.loadOrMakeKey()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] s in
                if case .ready = s { self?.running = true }
                if case .failed = s { self?.running = false }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            print("Churchfront Video network control didn't start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    /// A random key, made once and kept readable only by this user.
    static func loadOrMakeKey() -> String {
        if let t = try? String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 { return t }
        return newKey()
    }

    /// Makes a new key and replaces the old one: whoever had it stops working.
    @discardableResult
    static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: keyURL.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        return t
    }

    /// Replaces the key while running, too.
    func renewKey() { key = Self.newKey() }


    // MARK: Requests

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = got
            if let data { buf.append(data) }
            if let req = ControlServer.parse(buf) {
                self.handle(req) { status, body in ControlServer.reply(c, status, body) }
            } else if done || err != nil || buf.count > 1 << 16 {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    /// Equal without stopping at the first different character, so the time taken says nothing about the key.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func handle(_ r: ControlServer.Request, _ done: @escaping (Int, Any) -> Void) {
        let parts = URLComponents(string: "http://x" + r.path)
        let given = r.headers["x-cuevideo-key"] ?? parts?.queryItems?.first { $0.name == "key" }?.value ?? ""
        guard !key.isEmpty, Self.same(given, key) else { done(401, ["error": "Missing or wrong key."]); return }
        guard r.method == "GET" || r.method == "POST" else { done(400, ["error": "Use GET."]); return }
        guard let action = NetworkAction.route(parts?.path ?? r.path) else {
            done(404, ["error": "Try /cameras, or /camera/<name>/follow, wide, hold, shot/<name>, zoom/in."]); return
        }
        DispatchQueue.main.async { [self] in
            let (status, body) = perform(action)
            done(status, body)
        }
    }

    /// Does what was asked (on the main thread, like the app's own buttons).
    func perform(_ action: NetworkAction) -> (Int, [String: Any]) {
        func camera(_ name: String) -> VirtualCameraRuntime? { find(name) }
        func missing(_ name: String) -> (Int, [String: Any]) { (404, ["error": "No running virtual camera called \(name)."]) }
        func ok(_ text: String) -> (Int, [String: Any]) { (200, ["ok": true, "done": text]) }
        switch action {
        case .list:
            let cams = VirtualCameras.shared.all.map { r -> [String: Any] in
                let s = r.status()
                return ["name": r.camera.name, "mode": s.mode, "shot": s.shot, "live": s.captureLive, "saved_shots": r.camera.shots.map(\.name)]
            }
            return (200, ["cameras": cams])
        case .follow(let name, let size):
            guard let r = camera(name) else { return missing(name) }
            var shot: ShotSize?
            if let size {
                guard let s = ShotSize.named(size) else { return (400, ["error": "Unknown shot \(size). Use shoulders, waist or full."]) }
                shot = s
            }
            r.frame(as: shot, config: config())
            r.followPerson()
            return ok("\(r.camera.name) is following")
        case .wide(let name):
            guard let r = camera(name) else { return missing(name) }
            r.wide(); return ok("\(r.camera.name) is wide")
        case .hold(let name):
            guard let r = camera(name) else { return missing(name) }
            r.hold(); return ok("\(r.camera.name) is held")
        case .shot(let name, let shotName):
            guard let r = camera(name) else { return missing(name) }
            guard let shot = r.camera.shots.first(where: { $0.name.lowercased() == shotName.lowercased() }) else {
                return (404, ["error": "\(r.camera.name) has no saved shot called \(shotName)."])
            }
            r.go(to: shot); return ok("\(r.camera.name) is going to \(shot.name)")
        case .zoom(let name, let closer):
            guard let r = camera(name) else { return missing(name) }
            r.zoomManually(by: closer ? 0.85 : 1 / 0.85); return ok("\(r.camera.name) zoomed \(closer ? "in" : "out")")
        }
    }
}
