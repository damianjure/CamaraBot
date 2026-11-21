import Foundation
import Network

/// A small HTTP interface so other software on this Mac (the CueVideo MCP server that Claude
/// uses) can do anything the app's screens can. It listens on 127.0.0.1 only, and every
/// request must carry the key saved in ~/Library/Application Support/CueVideo/control-token.
///
///     GET  /tools                       the tool list (MCP tool definitions)
///     POST /call  {"name": ..., "arguments": {...}}   run one tool, returns its result
final class ControlServer {
    static let shared = ControlServer()
    static let port: UInt16 = 9911

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cuevideo.control")
    private(set) var token = ""
    private(set) var running = false

    static var tokenURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueVideo", isDirectory: true).appendingPathComponent("control-token")
    }

    func start() {
        token = Self.loadOrMakeToken()
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] s in
                if case .ready = s { self?.running = true }
                if case .failed = s { self?.running = false }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            print("Churchfront Video control server didn't start: \(error)")
        }
    }

    /// A random key, made once and kept readable only by this user.
    private static func loadOrMakeToken() -> String {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        return t
    }

    // MARK: Minimal HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = got
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.handle(req) { status, body in Self.reply(c, status, body) }
            } else if done || err != nil || buf.count > 4 << 20 {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }

    /// A whole request, or nil while more bytes are needed.
    static func parse(_ d: Data) -> Request? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[d.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return Request(method: "", path: "", headers: [:], body: Data()) }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard d.distance(from: bodyStart, to: d.endIndex) >= len else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers,
                       body: d.subdata(in: bodyStart..<d.index(bodyStart, offsetBy: len)))
    }

    static func reply(_ c: NWConnection, _ status: Int, _ body: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let text = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 404 ? "Not Found" : "Bad Request"))
        var head = "HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        if status == 0 { head = "" }
        c.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
    }

    private func handle(_ r: Request, _ done: @escaping (Int, Any) -> Void) {
        guard r.headers["x-cuevideo-token"] == token else { done(401, ["error": "Missing or wrong key."]); return }
        switch (r.method, r.path) {
        case ("GET", "/tools"):
            DispatchQueue.main.async { done(200, ["tools": ControlTools.definitions]) }
        case ("POST", "/call"):
            guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let name = obj["name"] as? String else {
                done(400, ["error": "Send {\"name\": tool, \"arguments\": {...}}."]); return
            }
            let args = obj["arguments"] as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                ControlTools.call(name, args) { result in done(200, result) }
            }
        default:
            done(404, ["error": "Use GET /tools or POST /call."])
        }
    }
}
